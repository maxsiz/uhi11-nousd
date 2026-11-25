import { NextResponse, type NextRequest } from "next/server";
import {
  FALLBACK_COOLDOWN_MS,
  RPC_ENV_BY_CHAIN_ID,
  RpcLimiter,
  checkRpcBody,
  clientKey,
  jsonRpcError,
  upstreamsFor,
} from "@/lib/server/rpc";

// Same-origin JSON-RPC proxy: the browser POSTs to /api/rpc/<chainId>, the upstream URL with its key
// stays in the server's environment. Cheap local checks first, the paid upstream last.

const UPSTREAM_TIMEOUT_MS = 15_000;
const limiter = new RpcLimiter();
const throttledUntil = new Map<string, number>();

const rpcError = (status: number, code: number, message: string, headers?: HeadersInit) =>
  new NextResponse(jsonRpcError(code, message), { status, headers: { "content-type": "application/json", ...headers } });

/** One terse line per refusal; never the body, which carries wallet addresses. */
function logReject(reason: string, chainId: number, key: string) {
  console.warn(JSON.stringify({ evt: "rpc.rejected", reason, chain: chainId, client: key.slice(0, 7) }));
}

export async function POST(req: NextRequest, props: { params: Promise<{ chainId: string }> }) {
  const chainId = Number((await props.params).chainId);
  const envVar = RPC_ENV_BY_CHAIN_ID[chainId];
  if (!envVar) return rpcError(400, -32602, `Unsupported chainId ${chainId}`);
  const { primary, fallback } = upstreamsFor(envVar, process.env);
  if (!primary) return rpcError(503, -32603, `RPC not configured for chain ${chainId}`);

  const body = await req.text();
  const key = clientKey(req.headers);
  const policy = checkRpcBody(body);
  if (!policy.ok) {
    logReject(policy.reason, chainId, key);
    return rpcError(policy.status, policy.code, policy.message);
  }
  const limit = limiter.take(key);
  if (!limit.allowed) {
    logReject("rate", chainId, key);
    return rpcError(429, -32005, "Too many requests", { "retry-after": String(limit.retryAfterSec) });
  }

  const forward = (url: string) =>
    fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  let res: Response;
  try {
    if (fallback && (throttledUntil.get(envVar) ?? 0) > Date.now()) {
      res = await forward(fallback);
    } else {
      res = await forward(primary);
      if (res.status === 429 && fallback) {
        await res.body?.cancel();
        throttledUntil.set(envVar, Date.now() + FALLBACK_COOLDOWN_MS);
        logReject("upstream-429:fallback", chainId, key);
        res = await forward(fallback);
      }
    }
  } catch (e) {
    const timedOut = e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError");
    logReject(timedOut ? "upstream-timeout" : "upstream-error", chainId, key);
    return rpcError(504, -32603, timedOut ? "Upstream timeout" : "Upstream error");
  }
  if (res.status === 429) logReject("upstream-429", chainId, key);
  return new NextResponse(await res.text(), { status: res.status, headers: { "content-type": "application/json" } });
}
