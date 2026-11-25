#!/usr/bin/env bash
# Unit tests of runtime modules, built with AddressSanitizer and UBSan.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
for t in tests/unit/*_test.c; do
  bin="build/$(basename "${t%.c}")"
  cc -O1 -g -Wall -Wno-unused-function -fsanitize=address,undefined -fno-sanitize-recover=all -Iruntime -o "$bin" "$t"
  "$bin"
done
