#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 machine into the MINA server. Run as root from a checkout of this
# repository (the instance's user data does that, see deploy/aws-provision.sh). Safe to rerun:
# it rebuilds and restarts, and never replaces an existing database.
#
#   MINA_REGION=<aws region> MINA_BUCKET=<backup bucket> MINA_SECRET_PARAM=<ssm name> \
#     deploy/server-setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MINA_REGION:?}" "${MINA_BUCKET:?}" "${MINA_SECRET_PARAM:?}"
NODE=v22.13.0
export DEBIAN_FRONTEND=noninteractive HOME="${HOME:-/root}"

apt-get update -q
apt-get install -yq build-essential git sqlite3 curl unzip xz-utils jq
# not the snap: snaps refuse to run for a user whose home is outside /home, as the backup's is
if ! command -v aws >/dev/null; then
  tmp=$(mktemp -d)
  (cd "$tmp" && curl -fsSLO https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip && unzip -q awscli-exe-linux-x86_64.zip && ./aws/install)
  rm -rf "$tmp"
fi

# The build needs more memory than the server does; this swap is removed again below.
if [ ! -f /swap.build ]; then
  fallocate -l 4G /swap.build && chmod 600 /swap.build && mkswap -q /swap.build
fi
swapon /swap.build 2>/dev/null || true

if [ ! -x /usr/local/bin/node ]; then
  tmp=$(mktemp -d)
  (cd "$tmp" && curl -fsSLO "https://nodejs.org/dist/$NODE/node-$NODE-linux-x64.tar.xz" \
    && curl -fsSLO "https://nodejs.org/dist/$NODE/SHASUMS256.txt" \
    && grep " node-$NODE-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c - \
    && tar -xJf "node-$NODE-linux-x64.tar.xz" -C /usr/local --strip-components=1)
  rm -rf "$tmp"
fi
# not corepack: the one shipped with this Node release rejects the registry's current signing key
command -v pnpm >/dev/null || npm install -g --silent "$(jq -r .packageManager frontend/package.json)"
[ -x "$HOME/.elan/bin/lake" ] ||
  curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none

./build.sh web
swapoff /swap.build && rm -f /swap.build

id mina >/dev/null 2>&1 || useradd --system --home /var/lib/mina --shell /usr/sbin/nologin mina
install -d -o mina -g mina -m 750 /var/lib/mina
install -d -m 755 /opt/mina /opt/mina/bin /opt/mina/tools /var/log/mina
install -m 755 bin/mina-server bin/mina-admin /opt/mina/bin/
install -m 755 tools/backup.sh /opt/mina/tools/

install -d -m 700 /etc/mina
secret=$(aws ssm get-parameter --region "$MINA_REGION" --name "$MINA_SECRET_PARAM" --with-decryption --query Parameter.Value --output text)
(umask 077; printf 'MINA_SECRET=%s\n' "$secret" >/etc/mina/secret.env)
printf 'MINA_REGION=%s\nMINA_BUCKET=%s\n' "$MINA_REGION" "$MINA_BUCKET" >/etc/mina/backup.env

if [ ! -f /var/lib/mina/mina.db ]; then
  sqlite3 /var/lib/mina/mina.db <gen/schema.sql
  chown mina:mina /var/lib/mina/mina.db
fi

install -m 644 deploy/mina.service deploy/mina-backup.service deploy/mina-backup.timer /etc/systemd/system/
install -m 755 deploy/backup-to-s3.sh /opt/mina/tools/
systemctl daemon-reload
systemctl enable -q mina.service mina-backup.timer
systemctl restart mina.service
systemctl start mina-backup.timer

# server log to CloudWatch
if ! [ -x /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl ]; then
  curl -fsSL -o /tmp/cwagent.deb "https://amazoncloudwatch-agent-$MINA_REGION.s3.$MINA_REGION.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb"
  dpkg -i /tmp/cwagent.deb && rm -f /tmp/cwagent.deb
fi
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "file:$PWD/deploy/cloudwatch-agent.json"

for _ in $(seq 50); do curl -sf -m 1 -o /dev/null http://127.0.0.1/v1/health && break; sleep 0.2; done
curl -sf -m 2 http://127.0.0.1/v1/health
echo
echo "mina is running: $(git rev-parse --short HEAD), $(uname -r), $(nproc) CPU, $(free -m | awk '/^Mem:/{print $2}') MB"
