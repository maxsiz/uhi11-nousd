import { describe, expect, it } from "vitest";
import { MAX_BATCH, RpcLimiter, checkRpcBody, clientKey, upstreamsFor } from "./rpc";

const call = (method: string) => ({ jsonrpc: "2.0", id: 1, method, params: [] });

describe("rpc proxy policy", () => {
  it("passes reads and refuses broadcasting and debug methods", () => {
    expect(checkRpcBody(JSON.stringify(call("eth_call"))).ok).toBe(true);
    for (const m of ["eth_sendRawTransaction", "eth_sendTransaction", "debug_traceCall", "admin_peers", "eth_mining"]) {
      const r = checkRpcBody(JSON.stringify(call(m)));
      expect(r.ok, m).toBe(false);
      if (!r.ok) expect(r.status).toBe(403);
    }
  });

  it("refuses a batch whole when one call is refused, and bounds batch size", () => {
    expect(checkRpcBody(JSON.stringify([call("eth_call"), call("eth_sendRawTransaction")])).ok).toBe(false);
    expect(checkRpcBody(JSON.stringify(Array(MAX_BATCH + 1).fill(call("eth_call")))).ok).toBe(false);
    expect(checkRpcBody("[]").ok).toBe(false);
    expect(checkRpcBody("not json").ok).toBe(false);
    expect(checkRpcBody(JSON.stringify({ id: 1 })).ok).toBe(false);
  });

  it("rate-limits per client and refills over time", () => {
    const l = new RpcLimiter(1, 2);
    expect(l.take("a", 0).allowed).toBe(true);
    expect(l.take("a", 0).allowed).toBe(true);
    expect(l.take("a", 0)).toEqual({ allowed: false, retryAfterSec: 1 });
    expect(l.take("b", 0).allowed).toBe(true);
    expect(l.take("a", 1000).allowed).toBe(true);
  });

  it("keys clients by Cloudflare's header first", () => {
    expect(clientKey(new Headers({ "cf-connecting-ip": "1.1.1.1", "x-forwarded-for": "2.2.2.2" }))).toBe("1.1.1.1");
    expect(clientKey(new Headers({ "x-forwarded-for": "2.2.2.2, 3.3.3.3" }))).toBe("2.2.2.2");
    expect(clientKey(new Headers())).toBe("unknown");
  });

  it("uses a fallback upstream only when it differs from the primary", () => {
    expect(upstreamsFor("X", { X: "a", X_FALLBACK: "b" })).toEqual({ primary: "a", fallback: "b" });
    expect(upstreamsFor("X", { X: "a", X_FALLBACK: "a" })).toEqual({ primary: "a", fallback: undefined });
    expect(upstreamsFor("X", {})).toEqual({ primary: undefined, fallback: undefined });
  });
});
