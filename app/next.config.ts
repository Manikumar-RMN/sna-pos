import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The browser tests (e2e-ui) build into their own folder so they never overwrite a normal build.
  distDir: process.env.NEXT_DIST_DIR || ".next",
  // Fail the production build on a type error rather than shipping one.
  typescript: { ignoreBuildErrors: false },
};

export default nextConfig;
