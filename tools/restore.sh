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
# - The database gets a new generation number (PRAGMA user_version), carried by every sync
#   answer.
#
# Events accepted after the backup are gone from the server. A client that synchronises
# afterwards sees the new generation and sends again, with the same event ids, everything it had
# been told was stored. What was sent from a device that never comes back stays lost: take
# backups often.
set -euo pipefail
[ $# = 2 ] || { sed -n '2,19p' "$0"; exit 2; }
FROM=$1 DB=$2
[ -f "$FROM" ] || { echo "no backup at $FROM" >&2; exit 1; }
result=$(sqlite3 -bail "$FROM" "PRAGMA integrity_check")
[ "$result" = ok ] || { echo "the backup fails its check: $result" >&2; exit 1; }
old=
if [ -f "$DB" ]; then
  # an exclusive lock can be had only if no other process has the database open
  if ! sqlite3 -bail "$DB" "PRAGMA locking_mode = EXCLUSIVE; BEGIN IMMEDIATE; COMMIT;" >/dev/null 2>&1; then
    echo "$DB is in use: stop the server first" >&2; exit 1
  fi
  old=$(sqlite3 "$DB" "PRAGMA user_version" 2>/dev/null || true)
  aside="$DB.before-restore-$(date +%Y%m%d-%H%M%S)"
  for suffix in "" -wal -shm; do [ ! -e "$DB$suffix" ] || mv -n "$DB$suffix" "$aside$suffix"; done
  echo "previous database kept as $aside"
fi
cp "$FROM" "$DB"
# A new generation tells clients to read again and to send again what the server may have lost.
# Random, so that it differs from earlier ones even when the replaced database cannot be read.
new=$old
while [ "$new" = "$old" ] || [ "$new" = "$(sqlite3 "$FROM" "PRAGMA user_version")" ] || [ "$new" = 0 ]; do
  new=$(( $(od -An -N4 -tu4 /dev/urandom) % 2147483646 + 1 ))
done
sqlite3 -bail "$DB" "PRAGMA user_version = $new"
sqlite3 -bail "$DB" "INSERT INTO events (seq, eid, region, vis, kind, actor, ts)
  SELECT coalesce(max(seq), 0) + 1000000000, randomblob(16), 1, 1, 0, 0, unixepoch() FROM events"
echo "restored $DB from $FROM; sequence numbers continue after $(sqlite3 "$DB" 'SELECT max(seq) FROM events')"
