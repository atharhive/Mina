#!/usr/bin/env bash
# A checked snapshot of the live database, copied to S3. Run by mina-backup.timer.
set -euo pipefail
: "${MINA_REGION:?}" "${MINA_BUCKET:?}"
name="mina-$(date -u +%Y%m%dT%H%M%SZ).db"
out="/var/lib/mina/$name"
trap 'rm -f "$out"' EXIT
/opt/mina/tools/backup.sh /var/lib/mina/mina.db "$out"
aws s3 cp --region "$MINA_REGION" --only-show-errors "$out" "s3://$MINA_BUCKET/backups/$name"
echo "uploaded s3://$MINA_BUCKET/backups/$name"
