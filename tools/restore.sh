#!/usr/bin/env bash
# Replace a database with a backup. Stop the server first.
#
#   tools/restore.sh <backup file> <database>
#
# - The replaced database and its write-ahead log are moved aside, never deleted. (A log left
#   from the old database must not be applied to the restored one.)
# - Sequence numbers jump forward by 1,000,000,000, recorded as one marker row (kind 0, seen by
#   no citizen). Without the jump the server would number new events like events it had already
#   sent, and a client that had read past the backup would never receive them.
#
# Events accepted after the backup are gone. Clients that were told they were delivered do not
# send them again: take backups often, and tell people after a restore.
set -euo pipefail
[ $# = 2 ] || { sed -n '2,13p' "$0"; exit 2; }
FROM=$1 DB=$2
[ -f "$FROM" ] || { echo "no backup at $FROM" >&2; exit 1; }
result=$(sqlite3 -bail "$FROM" "PRAGMA integrity_check")
[ "$result" = ok ] || { echo "the backup fails its check: $result" >&2; exit 1; }
if [ -f "$DB" ]; then
  # an exclusive lock can be had only if no other process has the database open
  if ! sqlite3 -bail "$DB" "PRAGMA locking_mode = EXCLUSIVE; BEGIN IMMEDIATE; COMMIT;" >/dev/null 2>&1; then
    echo "$DB is in use: stop the server first" >&2; exit 1
  fi
  aside="$DB.before-restore-$(date +%Y%m%d-%H%M%S)"
  for suffix in "" -wal -shm; do [ ! -e "$DB$suffix" ] || mv -n "$DB$suffix" "$aside$suffix"; done
  echo "previous database kept as $aside"
fi
cp "$FROM" "$DB"
sqlite3 -bail "$DB" "INSERT INTO events (seq, eid, region, vis, kind, actor, ts)
  SELECT coalesce(max(seq), 0) + 1000000000, randomblob(16), 1, 1, 0, 0, unixepoch() FROM events"
echo "restored $DB from $FROM; sequence numbers continue after $(sqlite3 "$DB" 'SELECT max(seq) FROM events')"
