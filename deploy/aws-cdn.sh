#!/usr/bin/env bash
# HTTPS in front of the server: a certificate and a CloudFront distribution.
#
#   deploy/aws-cdn.sh cert <domain>   request the certificate, print the DNS record to add
#   deploy/aws-cdn.sh dist <domain>   once it is issued: create the distribution
#
# Static files are cached at the edge as their Cache-Control headers say; /v1/* is never cached.
# CloudFront reaches the origin over plain HTTP; the security group admits nobody else.
set -euo pipefail
[ $# = 2 ] || { sed -n '2,8p' "$0"; exit 2; }
CMD=$1 DOMAIN=$2
REGION="${AWS_REGION:-ap-south-1}"
export AWS_PAGER=
cert_arn() {
  aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn | [0]" --output text
}

case $CMD in
  cert)
    ARN=$(cert_arn)
    [ "$ARN" != None ] || ARN=$(aws acm request-certificate --region us-east-1 --domain-name "$DOMAIN" --validation-method DNS --query CertificateArn --output text)
    sleep 5
    echo "Add this record at your DNS provider, then wait until the status is ISSUED:"
    aws acm describe-certificate --region us-east-1 --certificate-arn "$ARN" \
      --query 'Certificate.{status:Status,type:DomainValidationOptions[0].ResourceRecord.Type,name:DomainValidationOptions[0].ResourceRecord.Name,value:DomainValidationOptions[0].ResourceRecord.Value}' --output table ;;
  dist)
    ARN=$(cert_arn)
    [ "$ARN" != None ] && [ "$(aws acm describe-certificate --region us-east-1 --certificate-arn "$ARN" --query Certificate.Status --output text)" = ISSUED ] ||
      { echo "no issued certificate for $DOMAIN: run 'cert' and add the DNS record" >&2; exit 1; }
    IP=$(aws ec2 describe-addresses --region "$REGION" --filters Name=tag:Name,Values=mina-server --query 'Addresses[0].PublicIp' --output text)
    [ "$IP" != None ] || { echo "no server address: run deploy/aws-provision.sh" >&2; exit 1; }
    ORIGIN="ec2-${IP//./-}.$REGION.compute.amazonaws.com"
    config=$(jq -nc --arg d "$DOMAIN" --arg o "$ORIGIN" --arg arn "$ARN" '
      # managed policies: CachingOptimized, CachingDisabled, AllViewerExceptHostHeader
      def behaviour($cache): {TargetOriginId:"mina", ViewerProtocolPolicy:"redirect-to-https", Compress:false, CachePolicyId:$cache};
      def methods($m): {Quantity:($m|length), Items:$m, CachedMethods:{Quantity:2, Items:["GET","HEAD"]}};
      { CallerReference:("mina-" + $d), Comment:"MINA", Enabled:true, HttpVersion:"http2and3", IsIPV6Enabled:true,
        PriceClass:"PriceClass_200", Aliases:{Quantity:1, Items:[$d]},
        ViewerCertificate:{ACMCertificateArn:$arn, SSLSupportMethod:"sni-only", MinimumProtocolVersion:"TLSv1.2_2021"},
        Origins:{Quantity:1, Items:[{Id:"mina", DomainName:$o,
          CustomOriginConfig:{HTTPPort:80, HTTPSPort:443, OriginProtocolPolicy:"http-only", OriginReadTimeout:30, OriginKeepaliveTimeout:60}}]},
        DefaultCacheBehavior:(behaviour("658327ea-f89d-4fab-a63d-7e88639e58f6") + {AllowedMethods:methods(["GET","HEAD"])}),
        CacheBehaviors:{Quantity:1, Items:[behaviour("4135ea2d-6df8-44a3-9df3-4b5a84be39ad") + {PathPattern:"/v1/*",
          OriginRequestPolicyId:"b689b0a8-53d0-40ab-baf2-68738e2966ac",
          AllowedMethods:methods(["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"])}]} }')
    existing=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='MINA'].DomainName | [0]" --output text)
    [ "$existing" != None ] || existing=$(aws cloudfront create-distribution --distribution-config "$config" --query Distribution.DomainName --output text)
    echo "Add this record at your DNS provider:  $DOMAIN  CNAME  $existing"
    echo "Then check:  curl -I https://$DOMAIN/v1/health" ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
