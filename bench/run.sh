#!/usr/bin/env bash
# One benchmark run on this machine: the server alone on one CPU inside a 2 GB memory cgroup,
# the load generator on other CPUs, both in a private network namespace over loopback.
#
#   bench/run.sh <loadgen-binary> <users> <ramp_s> <hold_s> <rampdown_s> -- <server command...>
#
# The server command inherits the caller's environment and must listen on 127.0.0.1:$BENCH_PORT.
# Env: BENCH_PORT (3000), SERVER_CPU (0), LOAD_CPUS (2-11), LOAD_THREADS (8), SOURCE_IPS (16),
#      NOFILE (65535), WORKLOAD_ARG, SERVER_LOG (/dev/null)
#
# Prints one JSON line: the load generator's report plus the server cgroup's CPU time and memory.
# Loopback results are not comparable with a two-machine run: part of the receive path is
# charged to the client's CPU.
set -euo pipefail
[ $# -ge 7 ] && [ "$6" = "--" ] || { sed -n '2,12p' "$0"; exit 2; }
LOADGEN=$1 USERS=$2 RAMP=$3 HOLD=$4 DOWN=$5; shift 6
PORT=${BENCH_PORT:-3000}
UNIT=mina-bench-$$
TMP=$(mktemp -d)

unshare -rn sh -c 'ip link set lo up && echo ready && exec sleep infinity' >"$TMP/ns" & NS=$!
cleanup() {
  systemctl --user stop "$UNIT.scope" >/dev/null 2>&1 || true
  kill "$NS" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
for _ in $(seq 50); do grep -q ready "$TMP/ns" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$TMP/ns" || { echo "could not create a network namespace" >&2; exit 1; }
enter=(nsenter -t "$NS" -U -n --preserve-credentials)

systemd-run --user --scope --quiet --unit="$UNIT" -p MemoryMax=2G -p MemorySwapMax=0 -- \
  "${enter[@]}" prlimit --nofile="${NOFILE:-65535}:${NOFILE:-65535}" -- taskset -c "${SERVER_CPU:-0}" "$@" \
  >"${SERVER_LOG:-/dev/null}" 2>&1 &
for _ in $(seq 100); do "${enter[@]}" curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/${HEALTH_PATH:-v1/health}" && break; sleep 0.2; done
"${enter[@]}" curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/${HEALTH_PATH:-v1/health}" || { echo "server not healthy" >&2; exit 1; }
CG=/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "$UNIT.scope")

"${enter[@]}" taskset -c "${LOAD_CPUS:-2-11}" "$LOADGEN" 127.0.0.1 "$PORT" "$USERS" "$RAMP" "$HOLD" "$DOWN" \
  "${LOAD_THREADS:-8}" "${SOURCE_IPS:-16}" ${WORKLOAD_ARG:+"$WORKLOAD_ARG"} >"$TMP/load.json" & LG=$!
cpu() { awk -v k="$1" '$1==k{print $2}' "$CG/cpu.stat"; }
sleep "$RAMP"; u0=$(cpu usage_usec) s0=$(cpu system_usec)
sleep "$HOLD"; u1=$(cpu usage_usec) s1=$(cpu system_usec)
mem_hold=$(cat "$CG/memory.current")
sock_hold=$(awk '$1=="sock"{print $2}' "$CG/memory.stat")
kern_hold=$(awk '$1=="kernel"{print $2}' "$CG/memory.stat")
wait "$LG"
peak=$(cat "$CG/memory.peak")
alive=true; [ -n "$(cat "$CG/cgroup.procs" 2>/dev/null)" ] || alive=false

jq -c --argjson cpu $((u1 - u0)) --argjson sys $((s1 - s0)) --argjson mh "$mem_hold" --argjson sk "$sock_hold" --argjson kn "$kern_hold" \
  --argjson peak "$peak" --argjson alive "$alive" \
  '. + {server_cpu_pct: (($cpu / (.hold_s * 1e6) * 1000 | round) / 10),
        server_sys_share: (($sys / (if $cpu == 0 then 1 else $cpu end) * 100 | round) / 100),
        cpu_us_per_request: (if .requests_in_hold == 0 then null else (($cpu / .requests_in_hold * 100 | round) / 100) end),
        mem_hold_mb: ($mh / 1048576 | round), mem_sock_mb: ($sk / 1048576 | round), mem_kernel_mb: ($kn / 1048576 | round), mem_peak_mb: ($peak / 1048576 | round),
        server_alive: $alive}' "$TMP/load.json"
