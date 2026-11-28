#!/usr/bin/env bash
# First boot of a benchmark machine (user data runs it as root from a checkout):
#   bench/aws/node-setup.sh server|generator
# Raises the limits a few hundred thousand connections need. The machine's TCP buffer settings
# are left at the distribution's defaults, and both the settings and the commit are recorded
# with every result.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROLE=${1:?server or generator}
export DEBIAN_FRONTEND=noninteractive HOME="${HOME:-/root}"

cat >/etc/sysctl.d/90-mina-bench.conf <<'EOF'
fs.nr_open = 2097152
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl -q --system
systemctl disable --now ssh.socket ssh.service 2>/dev/null || true

apt-get update -q
apt-get install -yq build-essential sqlite3 curl unzip jq

case $ROLE in
  server)
    [ -x "$HOME/.elan/bin/lake" ] ||
      curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
    fallocate -l 4G /swap.build && chmod 600 /swap.build && mkswap -q /swap.build && swapon /swap.build
    ./build.sh
    swapoff /swap.build && rm -f /swap.build ;;
  generator)
    # the secondary private addresses EC2 assigned: configure any the image did not
    dev=$(ip -o -4 route show default | awk '{print $5; exit}')
    token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
    meta() { curl -fsS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"; }
    mac=$(meta mac)
    prefix=$(meta "network/interfaces/macs/$mac/subnet-ipv4-cidr-block" | cut -d/ -f2)
    for ip in $(meta "network/interfaces/macs/$mac/local-ipv4s"); do
      ip -4 addr show dev "$dev" | grep -qw "inet $ip" || ip addr add "$ip/$prefix" dev "$dev"
    done
    ip -o -4 addr show dev "$dev" scope global | awk '{sub(/\/.*/, "", $4); print $4}' | paste -sd, >/run/mina-sources
    mkdir -p bin
    cc -O2 -pthread -Wno-unused-function -DWORKLOAD='"workload_mina.h"' -Ibench -Iruntime -Igen \
      -o bin/loadgen-mina bench/loadgen.c bench/sign.c ;;
  *) echo "server or generator" >&2; exit 2 ;;
esac
touch /run/mina-ready
