// Policy for the same-origin JSON-RPC proxy `/api/rpc/<chainId>`. Ported from stablelp-ui
// (rpcPolicy / rpcLimit / rpcUpstream): a proxy without a policy is a free public RPC paid for by our
// provider quota, one `curl` away. Pure and network-free so the tests check it, not production.

/** Server-only variable that holds each chain's upstream URL. Names match unisafe's production .env. */
export const RPC_ENV_BY_CHAIN_ID: Record<number, string> = {
  1: "MAINNET_RPC_URL",
  130: "UNICHAIN_RPC_URL",
  42161: "ARBITRUM_RPC_URL",
  8453: "BASE_RPC_URL",
};

/**
 * Methods viem may send for reads, fee estimation and receipt polling. Enforced from day one: noUSD has
 * no legacy traffic to observe first. `eth_accounts` is here only because wagmi's mock connector (demo
 * mode) can route it to the transport; the upstream answers it with an empty list.
 */
export const ALLOWED_METHODS: ReadonlySet<string> = new Set([
  "eth_chainId",
  "eth_blockNumber",
  "eth_call",
  "eth_getBalance",
  "eth_getCode",
  "eth_getLogs",
  "eth_getBlockByNumber",
  "eth_getBlockByHash",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  "eth_getTransactionCount",
  "eth_estimateGas",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_feeHistory",
  "eth_accounts",
  "net_version",
]);

/** Broadcasting and debug namespaces are refused by name, never forwarded. */
const ALWAYS_DENIED = [/^eth_send(Raw)?Transaction$/, /^(debug|trace|admin|personal|miner|txpool)_/];

export const MAX_BODY_BYTES = 256 * 1024;
/** viem folds reads into one Multicall3 `eth_call`, so real batches are tiny; this bounds a hostile one. */
export const MAX_BATCH = 8;

export type PolicyResult =
  | { ok: true; methods: string[] }
  | { ok: false; status: number; code: number; message: string; reason: string };

const fail = (status: number, code: number, message: string, reason: string): PolicyResult => ({
  ok: false,
  status,
  code,
  message,
  reason,
});

export function checkRpcBody(text: string, allow: ReadonlySet<string> = ALLOWED_METHODS): PolicyResult {
  if (Buffer.byteLength(text, "utf8") > MAX_BODY_BYTES) return fail(413, -32600, "Request body too large", "body");
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return fail(400, -32700, "Parse error", "parse");
  }
  const items: unknown[] = Array.isArray(parsed) ? parsed : [parsed];
  if (items.length === 0) return fail(400, -32600, "Invalid Request", "empty-batch");
  if (items.length > MAX_BATCH) return fail(413, -32600, `Batch too large (${items.length} > ${MAX_BATCH})`, "batch");
  const methods: string[] = [];
  for (const item of items) {
    const method = typeof item === "object" && item !== null ? (item as { method?: unknown }).method : undefined;
    if (typeof method !== "string" || !method) return fail(400, -32600, "Invalid Request", "shape");
    // A batch mixing allowed and refused calls is refused whole: JSON-RPC has no partial answer.
    if (ALWAYS_DENIED.some((re) => re.test(method)) || !allow.has(method)) {
      return fail(403, -32601, `Method not allowed: ${method}`, `method:${method}`);
    }
    methods.push(method);
  }
  return { ok: true, methods };
}

/** JSON-RPC shaped error, so viem reports an RPC refusal rather than a broken response. */
export const jsonRpcError = (code: number, message: string) =>
  JSON.stringify({ jsonrpc: "2.0", id: null, error: { code, message } });

/**
 * Token bucket per client, in process memory: compose runs exactly one container, so one process sees
 * all traffic. Cloudflare is where abuse should die first; this is the backstop.
 */
export class RpcLimiter {
  private readonly buckets = new Map<string, { tokens: number; last: number }>();
  constructor(
    private readonly rate = 40,
    private readonly burst = 80,
    private readonly maxKeys = 10_000,
  ) {}

  take(key: string, now = Date.now()): { allowed: true } | { allowed: false; retryAfterSec: number } {
    if (this.buckets.size > this.maxKeys) this.buckets.clear();
    const b = this.buckets.get(key) ?? { tokens: this.burst, last: now };
    b.tokens = Math.min(this.burst, b.tokens + ((now - b.last) / 1000) * this.rate);
    b.last = now;
    this.buckets.set(key, b);
    if (b.tokens < 1) return { allowed: false, retryAfterSec: Math.max(1, Math.ceil((1 - b.tokens) / this.rate)) };
    b.tokens -= 1;
    return { allowed: true };
  }
}

/**
 * The client is `cf-connecting-ip` (set and overwritten by Cloudflare), else the first hop of
 * `x-forwarded-for`. Trustworthy only because traefik behind Cloudflare is the sole way in.
 */
export function clientKey(headers: Headers): string {
  const cf = headers.get("cf-connecting-ip");
  if (cf) return cf.trim();
  return (headers.get("x-forwarded-for")?.split(",")[0] ?? "").trim() || "unknown";
}

/** Primary upstream and an optional `<VAR>_FALLBACK`, tried only when the primary answers 429. */
export function upstreamsFor(envVar: string, env: Record<string, string | undefined>) {
  const primary = env[envVar] || undefined;
  const fallback = env[`${envVar}_FALLBACK`] || undefined;
  return { primary, fallback: fallback && fallback !== primary ? fallback : undefined };
}

export const FALLBACK_COOLDOWN_MS = 10_000;
