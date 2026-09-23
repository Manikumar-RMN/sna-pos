import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Fail the production build on a type error rather than shipping one.
  typescript: { ignoreBuildErrors: false },
};

export default nextConfig;
