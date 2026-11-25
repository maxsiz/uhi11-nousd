/** @type {import('next').NextConfig} */
const nextConfig = {
  // Production ships a Node standalone bundle (.next/standalone/server.js), built by the deploy
  // workflow with NEXT_OUTPUT_STANDALONE=1; local `next start` stays non-standalone.
  ...(process.env.NEXT_OUTPUT_STANDALONE === "1" ? { output: "standalone" } : {}),
  reactStrictMode: true,
  poweredByHeader: false,
  // Turbopack resolves wagmi's guarded optional requires without shims; the empty object also silences
  // the migration notice (same as stablelp-ui).
  turbopack: {},
  reactCompiler: true,
  async headers() {
    // Mint, redeem and claim open wallet prompts: no site may frame them (clickjacking).
    return [{ source: "/:path*", headers: [{ key: "Content-Security-Policy", value: "frame-ancestors 'none'" }] }];
  },
};

export default nextConfig;
