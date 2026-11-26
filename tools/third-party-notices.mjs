// The notices that go with the web applications compiled into the server: what MINA is licensed
// under, and the licence (and NOTICE) of every third-party package whose code is in the built
// files. Fails if a package has no licence file.
//   node tools/third-party-notices.mjs > THIRD-PARTY-LICENSES.txt
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const frontend = new URL("../frontend", import.meta.url).pathname;
const trees = JSON.parse(execFileSync("pnpm", ["-r", "list", "--prod", "--depth", "10", "--json"], { cwd: frontend, encoding: "utf8", maxBuffer: 1 << 26 }));
const packages = new Map();
const add = (path) => {
  const manifest = JSON.parse(readFileSync(join(path, "package.json"), "utf8"));
  if (!manifest.name.startsWith("@mina/")) packages.set(`${manifest.name} ${manifest.version}`, { path, license: manifest.license });
};
const walk = (dependencies = {}) => {
  for (const d of Object.values(dependencies)) {
    if (d.path) add(d.path);
    walk(d.dependencies);
  }
};
for (const project of trees) walk(project.dependencies);
// not a runtime dependency, but the style sheets it writes contain its own base styles
add(join(frontend, "citizen/node_modules/tailwindcss"));

let out = `MINA
Copyright (c) the MINA authors. Licensed under the GNU Affero General Public License, version 3.
Anyone using this service over a network is entitled to its source code:
https://github.com/atharhive/Mina
The server also contains SQLite (public domain).

The web applications contain code from the packages below.
`;
for (const [name, { path, license }] of [...packages].sort()) {
  const files = readdirSync(path).filter((f) => /^(licen[cs]e|notice)(\.(md|txt))?$/i.test(f)).sort();
  if (!files.some((f) => /^licen/i.test(f))) throw new Error(`${name}: no licence file in ${path}`);
  out += `\n${"=".repeat(78)}\n${name} (${license})\n${"=".repeat(78)}\n`;
  for (const f of files) out += `\n--- ${f} ---\n${readFileSync(join(path, f), "utf8").trim()}\n`;
}
process.stdout.write(out);
