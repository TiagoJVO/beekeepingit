import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// Online-only browser SPA (NFR-ROL-2, D-5): no PWA plugin, no service worker, no offline
// caching — deliberately absent. See admin/README.md.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5174,
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
    css: false,
    coverage: {
      provider: "v8",
      reportsDirectory: "./coverage",
      include: ["src/**/*.{ts,tsx}"],
      exclude: ["src/**/*.test.{ts,tsx}", "src/main.tsx", "src/vite-env.d.ts"],
    },
  },
});
