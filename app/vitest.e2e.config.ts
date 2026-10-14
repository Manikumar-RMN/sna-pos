import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

// End-to-end tests of the database money path: `npm run test:e2e`. Needs PostgreSQL 16+ server binaries installed.
export default defineConfig({
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  test: {
    environment: "node",
    include: ["e2e/**/*.e2e.test.ts"],
    globalSetup: ["e2e/global-setup.ts"],
    testTimeout: 60000,
    hookTimeout: 180000,
    fileParallelism: false,
  },
});
