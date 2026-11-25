/** @type {import('next').NextConfig} */
const nextConfig = {
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
