import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      // Short timings so the tests don't wait out real deadlines.
      miniflare: { bindings: { ACK_TIMEOUT_MS: "400", PUBLIC_BASE_URL: "https://relay.test" } },
    }),
  ],
});
