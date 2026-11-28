#!/usr/bin/env bash
# The always-on MINA server on AWS. CREATES PAID RESOURCES (a t3.small, 20 GB of gp3 and a
# public IPv4 address). Safe to rerun: what exists is kept.
#
#   deploy/aws-provision.sh <alert email>
#
# Creates: a cost budget with email alerts, an S3 bucket for backups, the signing secret in SSM
# Parameter Store, an instance role, a security group that admits only CloudFront, one instance
# built from the public repository at the current commit, a fixed address, alarms and a
# dashboard. Shell access is through SSM Session Manager; no port is open for SSH.
# Env: AWS_REGION (ap-south-1), REPO (https://github.com/atharhive/Mina.git), COMMIT (HEAD).
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# = 1 ] || { sed -n '2,13p' "$0"; exit 2; }
EMAIL=$1
export AWS_REGION="${AWS_REGION:-ap-south-1}" AWS_PAGER=
REPO="${REPO:-https://github.com/atharhive/Mina.git}"
COMMIT="${COMMIT:-$(git rev-parse HEAD)}"
git ls-remote "$REPO" | grep -q "^$COMMIT" || { echo "commit $COMMIT is not a branch head in $REPO: push it first" >&2; exit 1; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="mina-backup-$ACCOUNT-$AWS_REGION"
PARAM=/mina/secret

echo "== budget with alerts at 10, 25 and 50 USD (credits not subtracted)"
aws budgets describe-budget --account-id "$ACCOUNT" --budget-name mina >/dev/null 2>&1 ||
  aws budgets create-budget --account-id "$ACCOUNT" \
    --budget '{"BudgetName":"mina","BudgetType":"COST","TimeUnit":"MONTHLY","BudgetLimit":{"Amount":"50","Unit":"USD"},"CostTypes":{"IncludeCredit":false,"IncludeRefund":false}}' \
    --notifications-with-subscribers "$(jq -nc --arg e "$EMAIL" '[10,25,50] | map({Notification:{NotificationType:"ACTUAL",ComparisonOperator:"GREATER_THAN",Threshold:.,ThresholdType:"ABSOLUTE_VALUE"},Subscribers:[{SubscriptionType:"EMAIL",Address:$e}]})')"

echo "== bucket $BUCKET (private, backups kept 14 days)"
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null ||
  aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"backups","Status":"Enabled","Filter":{"Prefix":"backups/"},"Expiration":{"Days":14}}]}' >/dev/null

echo "== signing secret in Parameter Store"
aws ssm get-parameter --name "$PARAM" >/dev/null 2>&1 ||
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' |
    jq -Rc --arg n "$PARAM" '{Name:$n,Type:"SecureString",Value:.}' |
    aws ssm put-parameter --cli-input-json file:///dev/stdin >/dev/null

echo "== instance role"
if ! aws iam get-role --role-name mina-server >/dev/null 2>&1; then
  aws iam create-role --role-name mina-server --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
for p in AmazonSSMManagedInstanceCore CloudWatchAgentServerPolicy; do
  aws iam attach-role-policy --role-name mina-server --policy-arn "arn:aws:iam::aws:policy/$p"
done
aws iam put-role-policy --role-name mina-server --policy-name mina --policy-document "$(jq -nc \
  --arg b "arn:aws:s3:::$BUCKET/backups/*" --arg p "arn:aws:ssm:$AWS_REGION:$ACCOUNT:parameter$PARAM" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"s3:PutObject",Resource:$b},{Effect:"Allow",Action:"ssm:GetParameter",Resource:$p}]}')"
if ! aws iam get-instance-profile --instance-profile-name mina-server >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name mina-server >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name mina-server --role-name mina-server
  sleep 15   # a new profile takes a moment to reach EC2
fi

echo "== security group: port 80 from CloudFront only"
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=mina-server "Name=vpc-id,Values=$VPC" --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = None ]; then
  SG=$(aws ec2 create-security-group --group-name mina-server --description "MINA origin: CloudFront only" --vpc-id "$VPC" --query GroupId --output text)
  PL=$(aws ec2 describe-managed-prefix-lists --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing --query 'PrefixLists[0].PrefixListId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$PL}]" >/dev/null
fi

echo "== instance: t3.small, one core with one thread"
find_instance() {
  aws ec2 describe-instances --filters Name=tag:Name,Values=mina-server Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}
ID=$(find_instance)
if [ "$ID" = None ]; then
  AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
  userdata=$(mktemp); trap 'rm -f "$userdata"' EXIT
  cat >"$userdata" <<EOF
#!/bin/bash
exec >/var/log/mina-setup.log 2>&1
set -eux
export HOME=/root
apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -yq git
git clone '$REPO' /opt/mina-src
cd /opt/mina-src && git checkout -q '$COMMIT'
MINA_REGION='$AWS_REGION' MINA_BUCKET='$BUCKET' MINA_SECRET_PARAM='$PARAM' deploy/server-setup.sh
EOF
  # unlimited CPU credits while building; "standard" afterwards (see deploy/README.md)
  ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.small \
    --cpu-options CoreCount=1,ThreadsPerCore=1 --credit-specification CpuCredits=unlimited \
    --iam-instance-profile Name=mina-server --security-group-ids "$SG" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --metadata-options HttpTokens=required --user-data "file://$userdata" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=mina-server},{Key=project,Value=mina}]' 'ResourceType=volume,Tags=[{Key=project,Value=mina}]' \
    --query 'Instances[0].InstanceId' --output text)
fi
aws ec2 wait instance-running --instance-ids "$ID"

echo "== fixed address"
ALLOC=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=mina-server --query 'Addresses[0].AllocationId' --output text)
[ "$ALLOC" != None ] || ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=mina-server},{Key=project,Value=mina}]' --query AllocationId --output text)
aws ec2 associate-address --instance-id "$ID" --allocation-id "$ALLOC" >/dev/null

echo "== alarms and dashboard"
aws cloudwatch put-metric-alarm --alarm-name mina-recover --namespace AWS/EC2 --metric-name StatusCheckFailed_System \
  --dimensions "Name=InstanceId,Value=$ID" --statistic Maximum --period 60 --evaluation-periods 2 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold --alarm-actions "arn:aws:automate:$AWS_REGION:ec2:recover"
aws cloudwatch put-metric-alarm --alarm-name mina-cpu --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions "Name=InstanceId,Value=$ID" --statistic Average --period 300 --evaluation-periods 3 --threshold 80 \
  --comparison-operator GreaterThanThreshold
aws cloudwatch put-dashboard --dashboard-name mina --dashboard-body "$(jq -nc --arg id "$ID" --arg r "$AWS_REGION" '
  def w($x; $y; $title; $metrics): {type:"metric",x:$x,y:$y,width:12,height:6,properties:{title:$title,region:$r,period:300,metrics:$metrics}};
  {widgets:[
    w(0;0;"CPU %";[["AWS/EC2","CPUUtilization","InstanceId",$id]]),
    w(12;0;"Network bytes";[["AWS/EC2","NetworkIn","InstanceId",$id],["AWS/EC2","NetworkOut","InstanceId",$id]]),
    w(0;6;"CPU credits";[["AWS/EC2","CPUCreditBalance","InstanceId",$id],["AWS/EC2","CPUSurplusCreditBalance","InstanceId",$id]]),
    w(12;6;"Status check failures";[["AWS/EC2","StatusCheckFailed","InstanceId",$id]])]}')" >/dev/null

IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].PublicIp' --output text)
cat <<EOF

instance  $ID
address   $IP
bucket    $BUCKET
commit    $COMMIT

The instance now builds MINA (several minutes). Follow it with:
  aws ssm start-session --region $AWS_REGION --target $ID
  sudo tail -f /var/log/mina-setup.log
Then: deploy/aws-cdn.sh cert <domain>
EOF
