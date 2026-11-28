#!/usr/bin/env bash
# The benchmark on AWS: one server under test and three load generators in one subnet.
# CREATES PAID RESOURCES. The machines terminate themselves after MAX_HOURS even if forgotten.
#
#   bench/aws/fleet.sh up                       launch and wait until all four are built
#   bench/aws/fleet.sh step <users> <ramp_s> <hold_s> <rampdown_s>
#   bench/aws/fleet.sh down                     terminate them and delete the security group
#   bench/aws/fleet.sh status                   what is running
#
# A step appends one JSON line to bench/reports/aws-steps.jsonl. Env: AWS_REGION (ap-south-1),
# GEN_TYPE (c7i-flex.large), MAX_HOURS (6), REPO, COMMIT (HEAD, must be pushed), EVENTS,
# REGIONS, MINA_SYNC (full). Needs the instance profile made by deploy/aws-provision.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
export AWS_REGION="${AWS_REGION:-ap-south-1}" AWS_PAGER=
GEN_TYPE=${GEN_TYPE:-c7i-flex.large} MAX_HOURS=${MAX_HOURS:-6} GENERATORS=3
REPO="${REPO:-https://github.com/atharhive/Mina.git}"
EVENTS=${EVENTS:-200000} REGIONS=${REGIONS:-64} SYNC=${MINA_SYNC:-full}

ids() {   # ids <role> [field]
  aws ec2 describe-instances --filters "Name=tag:mina-bench,Values=$1" Name=instance-state-name,Values=pending,running \
    --query "Reservations[].Instances[].${2:-InstanceId}" --output text | tr '\t' '\n' | sort
}

# remote <instance> <command>: run it as root, print its output, fail if it fails
send() {
  aws ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript --timeout-seconds 120 \
    --parameters "$(jq -nc --arg c "$2" '{commands:[$c], executionTimeout:["3600"]}')" --query Command.CommandId --output text
}
receive() {   # receive <instance> <command id>
  local state
  while :; do
    state=$(aws ssm get-command-invocation --instance-id "$1" --command-id "$2" --query Status --output text 2>/dev/null || echo Pending)
    case $state in Pending | InProgress | Delayed) sleep 5 ;; *) break ;; esac
  done
  aws ssm get-command-invocation --instance-id "$1" --command-id "$2" --query StandardOutputContent --output text
  [ "$state" = Success ] || {
    aws ssm get-command-invocation --instance-id "$1" --command-id "$2" --query StandardErrorContent --output text >&2
    return 1
  }
}
remote() { receive "$1" "$(send "$1" "$2")"; }

launch() {   # launch <role> <count> <type> <extra run-instances arguments>
  local role=$1 count=$2 type=$3; shift 3
  local userdata; userdata=$(mktemp)
  cat >"$userdata" <<EOF
#!/bin/bash
exec >/var/log/mina-setup.log 2>&1
set -eux
export HOME=/root
shutdown -h +$((MAX_HOURS * 60))
apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -yq git
git clone '$REPO' /opt/mina-src
cd /opt/mina-src && git checkout -q '$COMMIT' && bench/aws/node-setup.sh $role
EOF
  aws ec2 run-instances --count "$count" --image-id "$AMI" --instance-type "$type" \
    --iam-instance-profile Name=mina-server --instance-initiated-shutdown-behavior terminate \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
    --metadata-options HttpTokens=required --user-data "file://$userdata" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=mina-bench-$role},{Key=mina-bench,Value=$role},{Key=project,Value=mina}]" \
    "$@" --query 'Instances[].InstanceId' --output text
  rm -f "$userdata"
}

case ${1:-} in
  up)
    COMMIT="${COMMIT:-$(git rev-parse HEAD)}"
    git ls-remote "$REPO" | grep -q "^$COMMIT" || { echo "push commit $COMMIT first" >&2; exit 1; }
    [ -z "$(ids server)$(ids generator)" ] || { echo "a fleet is already running: $0 down" >&2; exit 1; }
    AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
    VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
    # one availability zone for all four, one that offers both instance types
    ZONE=$(comm -12 \
      <(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=t3.small --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort) \
      <(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters "Name=instance-type,Values=$GEN_TYPE" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort) | head -1)
    SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=availability-zone,Values=$ZONE" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
    # EC2 tracks every connection against a per-instance limit unless the rules admit the traffic
    # from anywhere in both directions. Hence open rules, on short-lived machines with synthetic
    # data and SSH switched off.
    group() {   # group <name> <from port> <to port>
      local id; id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC" --query 'SecurityGroups[0].GroupId' --output text)
      if [ "$id" = None ]; then
        id=$(aws ec2 create-security-group --group-name "$1" --description "MINA benchmark, temporary" --vpc-id "$VPC" --query GroupId --output text)
        aws ec2 authorize-security-group-ingress --group-id "$id" --protocol tcp --port "$2-$3" --cidr 0.0.0.0/0 >/dev/null
      fi
      echo "$id"
    }
    SGS=$(group mina-bench-server 3000 3000) SGG=$(group mina-bench-generator 0 65535)
    echo "== launching in $ZONE; they terminate by themselves after $MAX_HOURS h"
    launch server 1 t3.small --cpu-options CoreCount=1,ThreadsPerCore=1 --credit-specification CpuCredits=unlimited \
      --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET,Groups=$SGS,AssociatePublicIpAddress=true"
    launch generator $GENERATORS "$GEN_TYPE" \
      --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET,Groups=$SGG,AssociatePublicIpAddress=true,SecondaryPrivateIpAddressCount=2" ||
      { echo "generators failed to launch; run '$0 down'" >&2; exit 1; }
    for id in $(ids server) $(ids generator); do
      echo "== waiting for $id"
      aws ec2 wait instance-status-ok --instance-ids "$id"
      remote "$id" 'for i in $(seq 170); do [ -f /run/mina-ready ] && exit 0; grep -q "scripts-user.*FAIL\|Failed to run module" /var/log/cloud-init.log && break; sleep 10; done; tail -40 /var/log/mina-setup.log >&2; exit 1'
    done
    echo "ready" ;;

  step)
    [ $# = 5 ] || { sed -n '2,13p' "$0"; exit 2; }
    USERS=$2 RAMP=$3 HOLD=$4 DOWN=$5
    SERVER=$(ids server); mapfile -t GENS < <(ids generator)
    [ -n "$SERVER" ] && [ ${#GENS[@]} = $GENERATORS ] || { echo "the fleet is not complete: $0 status" >&2; exit 1; }
    IP=$(ids server PrivateIpAddress)
    SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    cd_="cd /opt/mina-src && export HOME=/root && git config --global --add safe.directory /opt/mina-src"
    echo "== seeding and starting the server"
    remote "$SERVER" "$cd_ && EVENTS=$EVENTS REGIONS=$REGIONS MINA_SYNC=$SYNC bench/aws/server-step.sh start $SECRET"
    per=$((USERS / GENERATORS))
    cmds=()
    for i in "${!GENS[@]}"; do
      n=$per; [ "$i" = 0 ] && n=$((USERS - per * (GENERATORS - 1)))
      cmds+=("$(send "${GENS[$i]}" "cd /opt/mina-src && ulimit -n 1048576 && MINA_UID_BASE=$(((i + 1) * 10000000)) bin/loadgen-mina $IP 3000 $n $RAMP $HOLD $DOWN 2 \"\$(cat /run/mina-sources)\" $SECRET:$EVENTS:$REGIONS")")
    done
    echo "== $USERS users: ramp $RAMP s, hold $HOLD s"
    measured=$(remote "$SERVER" "$cd_ && MINA_SYNC=$SYNC bench/aws/server-step.sh measure $RAMP $HOLD")
    results=$(for i in "${!GENS[@]}"; do receive "${GENS[$i]}" "${cmds[$i]}" | grep '^{'; done | jq -sc .)
    stopped=$(remote "$SERVER" "$cd_ && EVENTS=$EVENTS bench/aws/server-step.sh stop")
    mkdir -p bench/reports
    jq -nc --argjson g "$results" --argjson m "$measured" --argjson s "$stopped" --arg date "$(date -u +%FT%TZ)" --arg region "$AWS_REGION" --arg gen "$GEN_TYPE" '
      def total(f): [$g[] | f] | add;
      {date: $date, region: $region, generators: "\($g | length) x \($gen)",
       users: total(.users), ramp_s: $g[0].ramp_s, hold_s: $g[0].hold_s,
       open_conns_min_in_hold: total(.open_conns_min_in_hold),
       nominal_rps: total(.nominal_rps), achieved_rps: total(.achieved_rps),
       errors_in_hold: total(.errors_in_hold), errors: (reduce $g[].errors as $e ({}; reduce ($e | to_entries[]) as $x (.; .[$x.key] += $x.value))),
       unexpected_answers: total(.workload.unexpected),
       p50_ms_worst: ([$g[].p50_ms] | max), p99_ms_worst: ([$g[].p99_ms] | max), max_ms: ([$g[].max_ms] | max),
       new_events_acknowledged: total(.workload.new_events_acknowledged)} + $m + $s + {per_generator: $g}
      | .events_stored = .events_at_end - .events_at_start' | tee -a bench/reports/aws-steps.jsonl | jq 'del(.per_generator)' ;;

  down)
    all="$(ids server) $(ids generator)"
    if [ -n "${all// /}" ]; then
      aws ec2 terminate-instances --instance-ids $all >/dev/null
      aws ec2 wait instance-terminated --instance-ids $all
    fi
    for g in mina-bench-server mina-bench-generator; do
      id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$g" --query 'SecurityGroups[0].GroupId' --output text)
      [ "$id" = None ] || aws ec2 delete-security-group --group-id "$id" >/dev/null
    done
    left="$(ids server)$(ids generator)"
    [ -z "$left" ] && echo "no benchmark machine is running" || { echo "still running: $left" >&2; exit 1; } ;;

  status)
    aws ec2 describe-instances --filters Name=tag-key,Values=mina-bench Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`mina-bench`]|[0].Value,InstanceType,State.Name,LaunchTime]' --output table ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
