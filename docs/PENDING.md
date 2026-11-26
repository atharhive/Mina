# Pending: what cannot be done yet

Only work that is **blocked** is listed here, with what would unblock it. Work that can be done
now belongs in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) instead. Remove an entry when it
is done.

| Item | Blocked because | Unblocked by |
|---|---|---|
| Load tests above 100,000 users, including the 300,000 target | one development machine holds the server and the load generator | cloud machines: one server and about three load generators, paid, approved before launch. The generator's multi-address support and a setup script come first |
| AWS deployment: persistent disk, backups to object storage, monitoring, least-privilege access | no cloud environment | the same |
| Kernel CPU profile of the loaded server (about two thirds of its time is in the kernel) | `perf` is restricted on the development machine | `sudo sysctl kernel.perf_event_paranoid=1`, which needs the machine owner's password |
| HTTPS, and with it offline use on real phones | no domain name or certificate | a domain and a certificate, or a TLS proxy the test phones trust. Browsers refuse service workers and location without it |
| Testing on real phones and slow mobile networks | no test devices on a trusted connection | HTTPS (above) and a phone |
| Geographic basemap in the responder view | map tiles must come from somewhere, and a public tile service would break offline use and the same-origin content policy | a choice of tile data to host with the server (for example a regional extract), with its licence and size |
| Coverage-guided fuzzing of the parsers | clang with libFuzzer is not installed on the development machine | installing it, which needs the machine owner's password (for example `sudo apt install clang`) |
| Power cuts on real hardware | no machine and drive that may be cut; `tests/powerloss.mjs` simulates the drive's cache only | a test machine whose power can be switched off |
| Translations | no target languages chosen, and no one to check the wording of emergency messages | the languages, and a speaker of each |
| Review by someone other than the author, including security | all code and tests so far come from one author | a human reviewer, or an externally run review |
