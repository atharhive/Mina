#!/usr/bin/env bash
# The server side of one load step, run as root on the benchmark server.
#
#   server-step.sh start <secret>          fresh seeded database, server up (EVENTS, REGIONS)
#   server-step.sh measure <ramp_s> <hold_s>   sleep over the ramp, then measure the hold
#   server-step.sh stop                    stop the server, check the database
set -euo pipefail
cd "$(dirname "$0")/../.."
EVENTS=${EVENTS:-200000} REGIONS=${REGIONS:-64} SYNC=${MINA_SYNC:-full}
DIR=/var/lib/mina-bench DB=/var/lib/mina-bench/mina.db LOG=/var/log/mina-bench.log
CG=/sys/fs/cgroup/system.slice/mina-bench.service
cpu() { awk -v k="$1" '$1==k{print $2}' "$CG/cpu.stat"; }
mem() { awk -v k="$1:" '$1==k{print int($2/1024)}' /proc/meminfo; }
allowance() {   # packets the EC2 network dropped or delayed because of an instance limit
  local dev; dev=$(ip -o -4 route show default | awk '{print $5; exit}')
  ethtool -S "$dev" 2>/dev/null | awk -F: '/allowance_exceeded/{gsub(/ /,""); printf "%s\"%s\":%s", s, $1, $2; s=","} END{}'
}

case ${1:-} in
  start)
    systemctl stop mina-bench 2>/dev/null || true
    sleep 3          # ring memory is returned a moment after the process ends
    mkdir -p $DIR && rm -f $DB $DB-wal $DB-shm && : >$LOG
    sqlite3 $DB <gen/schema.sql
    bin/mina-admin seed --events "$EVENTS" --regions "$REGIONS" --seed 1 | sqlite3 -bail $DB
    sync
    systemd-run --quiet --unit=mina-bench -p LimitNOFILE=1048576 -p LimitMEMLOCK=infinity \
      -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" \
      -E MINA_DB=$DB -E "MINA_SECRET=$2" -E MINA_HOST=0.0.0.0 -E MINA_PORT=3000 -E "MINA_SYNC=$SYNC" "$PWD/bin/mina-server"
    for _ in $(seq 100); do curl -sf -m 1 -o /dev/null http://127.0.0.1:3000/v1/health && exit 0; sleep 0.2; done
    cat $LOG >&2; exit 1 ;;
  measure)
    sleep "$2"
    u0=$(cpu usage_usec) s0=$(cpu system_usec) t0=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8+$9, $5+$6, $9}' /proc/stat)
    sleep $(($3 - 5))
    established=$(ss -Htn state established '( sport = :3000 )' | wc -l)
    sockstat=$(awk '$1=="TCP:"{for(i=2;i<NF;i+=2) if($i=="mem") print int($(i+1)*4096/1048576)}' /proc/net/sockstat)
    rss=$(awk '/^VmRSS/{print int($2/1024)}' "/proc/$(systemctl show -p MainPID --value mina-bench)/status")
    avail=$(mem MemAvailable) total=$(mem MemTotal) cgmem=$(($(cat $CG/memory.current) / 1048576))
    u1=$(cpu usage_usec) s1=$(cpu system_usec) t1=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8+$9, $5+$6, $9}' /proc/stat)
    hz=$(getconf CLK_TCK)
    jq -nc --argjson cpu $((u1 - u0)) --argjson sys $((s1 - s0)) --argjson wall $(($3 - 5)) --argjson hz "$hz" \
      --arg t0 "$t0" --arg t1 "$t1" --argjson est "$established" --argjson sk "$sockstat" --argjson rss "$rss" \
      --argjson avail "$avail" --argjson total "$total" --argjson cg "$cgmem" --argjson net "{$(allowance)}" \
      --arg commit "$(git rev-parse --short HEAD)" --arg kernel "$(uname -r)" --argjson cpus "$(nproc)" --arg sync "$SYNC" \
      --arg type "$(cat /sys/devices/virtual/dmi/id/product_name)" '
      ($t0 | split(" ") | map(tonumber)) as $a | ($t1 | split(" ") | map(tonumber)) as $b |
      {instance: $type, cpus: $cpus, kernel: $kernel, commit: $commit, durability: $sync,
       server_cpu_pct: ($cpu / ($wall * 1e6) * 1000 | round / 10),
       server_sys_share: ($sys / ([$cpu, 1] | max) * 100 | round / 100),
       machine_steal_s: (($b[2] - $a[2]) / $hz),
       established: $est, tcp_buffers_mb: $sk, server_rss_mb: $rss, server_cgroup_mb: $cg,
       machine_used_mb: ($total - $avail), machine_total_mb: $total, ec2_network_allowance: $net}' ;;
  stop)
    alive=$(systemctl is-active mina-bench || true)
    peak=$(($(cat $CG/memory.peak 2>/dev/null || echo 0) / 1048576))
    systemctl stop mina-bench 2>/dev/null || true
    oom=$(dmesg | grep -ciE 'out of memory|tcp: out of memory' || true)
    warnings=$(grep -cE 'native plan failed|another connection|batch rolled back|checkpointed in the request thread' $LOG || true)
    jq -nc --arg alive "$alive" --argjson peak "$peak" --argjson oom "$oom" --argjson w "$warnings" \
      --argjson end "$(sqlite3 $DB 'SELECT count(*) FROM events')" --argjson start "$EVENTS" \
      --arg integrity "$(sqlite3 $DB 'PRAGMA integrity_check')" \
      '{server_active_at_end: ($alive == "active"), server_peak_mb: $peak, kernel_oom_lines: $oom, log_warnings: $w,
        events_at_start: $start, events_at_end: $end, integrity: $integrity}' ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
