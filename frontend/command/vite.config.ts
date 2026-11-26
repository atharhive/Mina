import tailwind from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  base: "/command/",
  plugins: [react(), tailwind()],
  server: { proxy: { "/v1": "http://127.0.0.1:8080" } },     // a local mina-server, in development
});
