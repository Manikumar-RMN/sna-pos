import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

// Browser tests of the real app: `npm run test:ui`. Needs PostgreSQL 16+ server binaries, the PostgREST binary and Chromium.
export default defineConfig({
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  test: { environment: "node", include: ["e2e-ui/**/*.ui.test.ts"], globalSetup: ["e2e-ui/global-setup.ts"], testTimeout: 120000, hookTimeout: 900000, fileParallelism: false },
});
