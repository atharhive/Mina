#!/usr/bin/env bash
# A consistent copy of a database while the server uses it.
#
#   tools/backup.sh <database> <new file>
#
# VACUUM INTO reads one snapshot, so it finishes however fast the server writes (SQLite's
# page-by-page backup starts over after every foreign commit), and writers are not blocked in
# WAL mode. The copy is checked before it is reported as good. Needs sqlite3 3.27 or newer.
set -euo pipefail
[ $# = 2 ] || { sed -n '2,8p' "$0"; exit 2; }
DB=$1 OUT=$2
[ -f "$DB" ] || { echo "no database at $DB" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "$OUT exists; choose a new file name" >&2; exit 1; }
case "$OUT" in *\'*) echo "the file name must not contain a quote" >&2; exit 1 ;; esac
sqlite3 -bail "$DB" ".timeout 5000" "VACUUM INTO '$OUT'"
result=$(sqlite3 -bail "$OUT" "PRAGMA integrity_check")
[ "$result" = ok ] || { echo "the copy failed its check: $result" >&2; exit 1; }
echo "backup written: $OUT, newest event $(sqlite3 "$OUT" 'SELECT coalesce(max(seq), 0) FROM events')"
