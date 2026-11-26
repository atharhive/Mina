import tailwind from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { serviceWorker } from "../shared/sw/plugin.ts";

export default defineConfig({
  plugins: [react(), tailwind(), serviceWorker("citizen")],
  server: { proxy: { "/v1": "http://127.0.0.1:8080" } },     // a local mina-server, in development
});
