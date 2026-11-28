# Deploying MINA on AWS

One `t3.small` (one core, one thread, 2 GB) in `ap-south-1` behind CloudFront. Both scripts
create resources that cost money. They need the AWS CLI v2 (signed in) and `jq`.

```bash
deploy/aws-provision.sh <alert email>     # budget, bucket, secret, role, firewall, server, alarms
deploy/aws-cdn.sh cert <domain>           # then add the printed DNS record
deploy/aws-cdn.sh dist <domain>           # then add the printed CNAME
```

The commit to deploy must be pushed: the instance clones the public repository.

## After the first build

The instance is launched with unlimited CPU credits so that the build is not throttled. Switch
it to `standard`, which cannot add charges:

```bash
aws ec2 modify-instance-credit-specification --region ap-south-1 \
  --instance-credit-specifications InstanceId=<id>,CpuCredits=standard
```

## Operating it

Shell: `aws ssm start-session --region ap-south-1 --target <id>`. No SSH port is open.

```bash
systemctl status mina; tail -f /var/log/mina/server.log
sudo systemctl start mina-backup; journalctl -u mina-backup      # back up now
# a responder token (the secret stays on the server)
sudo bash -c 'set -a; . /etc/mina/secret.env; /opt/mina/bin/mina-admin token --sub 100 --role responder --regions 1 --ttl 86400'
# update to a newer commit
cd /opt/mina-src && sudo git fetch && sudo git checkout <commit> &&
  sudo -H MINA_REGION=ap-south-1 MINA_BUCKET=<bucket> MINA_SECRET_PARAM=/mina/secret deploy/server-setup.sh
```

Restoring a backup: `tools/restore.sh`; read its header first.

## Taking it down

Terminate the instance, release the Elastic IP, disable and then delete the distribution, empty
and delete the bucket, delete the certificate, the alarms, the dashboard, the log groups, the
parameter, the role and the budget.
