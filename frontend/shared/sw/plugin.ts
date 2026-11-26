import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** Vite plugin: writes sw.js with the list of built files and a version derived from their names
 * and the contents of those whose names do not carry a hash. */
export function serviceWorker(app: string) {
  let base = "/";
  let root = ".";
  return {
    name: "mina-service-worker",
    apply: "build" as const,
    configResolved(config: { base: string; root: string }) {
      base = config.base;
      root = config.root;
    },
    generateBundle(this: { emitFile(file: { type: "asset"; fileName: string; source: string }): void }, _: unknown, bundle: Record<string, unknown>) {
      const publicFiles = readdirSync(join(root, "public"));
      const files = ["index.html", ...Object.keys(bundle).filter((f) => f !== "index.html"), ...publicFiles];
      const assets = files.map((f) => base + f);
      const hash = createHash("sha256").update(JSON.stringify(assets));
      for (const f of publicFiles) hash.update(readFileSync(join(root, "public", f)));
      hash.update(readFileSync(join(root, "index.html")));
      const template = readFileSync(fileURLToPath(new URL("./sw.template.js", import.meta.url)), "utf8");
      const values = { APP: app, BASE: base, VERSION: hash.digest("hex").slice(0, 12), ASSETS: assets };
      const source = Object.entries(values).map(([name, value]) => `const ${name} = ${JSON.stringify(value)};\n`).join("") + template;
      this.emitFile({ type: "asset", fileName: "sw.js", source });
    },
  };
}
