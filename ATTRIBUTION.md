# Attribution

MINA is licensed under the GNU Affero General Public License, version 3 (`LICENSE`).

Third-party software it uses. None of it is stored in this repository.

## In the server

| Component | Version | Licence | How it is used |
|---|---|---|---|
| [SQLite](https://sqlite.org) amalgamation | 3.54.1 | public domain | downloaded by `build.sh` (SHA-256 checked) and compiled into the server |

## In the web applications (`./build.sh web` compiles them into the server)

| Component | Version | Licence |
|---|---|---|
| [React](https://react.dev), React DOM | 19.3.1 | MIT |
| Scheduler (part of React) | 0.28.0 | MIT |
| [Dexie.js](https://dexie.org) | 4.4.7 | Apache-2.0 |
| [Tailwind CSS](https://tailwindcss.com) (base styles in the built style sheets) | 4.3.5 | MIT |

Their licence and notice texts are written at build time to `/THIRD-PARTY-LICENSES.txt`, which
the server serves with the applications (`tools/third-party-notices.mjs`).

## Build and test tools (not distributed)

| Component | Version | Licence |
|---|---|---|
| [Lean 4](https://github.com/leanprover/lean4), installed by the developer | 4.35.0 | Apache-2.0 |
| Vite, TypeScript, Vitest, Playwright, Lighthouse, fake-indexeddb and others in `frontend/pnpm-lock.yaml` | as locked | their own |
