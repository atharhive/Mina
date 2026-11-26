import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import tailwind from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

/** Writes sw.js with the list of built files and a version derived from their names and the
 * contents of those whose names do not carry a hash. */
function serviceWorker(): Plugin {
  return {
    name: "mina-service-worker",
    apply: "build",
    generateBundle(_, bundle) {
      const publicFiles = readdirSync("public");
      const assets = ["/index.html", ...Object.keys(bundle).filter((f) => f !== "index.html"), ...publicFiles].map((f) => (f.startsWith("/") ? f : `/${f}`));
      const hash = createHash("sha256").update(JSON.stringify(assets));
      for (const f of publicFiles) hash.update(readFileSync(`public/${f}`));
      hash.update(readFileSync("index.html"));
      const version = hash.digest("hex").slice(0, 12);
      const source = `const VERSION = ${JSON.stringify(version)};\nconst ASSETS = ${JSON.stringify(assets)};\n${readFileSync("sw.template.js", "utf8")}`;
      this.emitFile({ type: "asset", fileName: "sw.js", source });
    },
  };
}

export default defineConfig({ plugins: [react(), tailwind(), serviceWorker()] });
