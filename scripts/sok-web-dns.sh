#!/usr/bin/env bash
###############################################################################
# sok-web-dns.sh — point a Route53 CNAME at the ALB the AWS Load Balancer
# Controller provisions for the Splunk Web Ingress (terraform/layers/sok/
# web-ingress.tf). The ALB is created asynchronously AFTER the Ingress, so its
# DNS name isn't known at terraform apply time; this script (called from a
# null_resource local-exec) waits for it and UPSERTs the record, and DELETEs it
# on destroy.
#
#   sok-web-dns.sh upsert <zone_id> <hostname> [namespace] [ingress_name]
#   sok-web-dns.sh delete <zone_id> <hostname> [namespace] [ingress_name]
#
# A stable URL across nightly rebuilds wants the external-dns addon instead —
# this is the low-dependency path for demo/opt-in use.
###############################################################################
set -euo pipefail

action=${1:?usage: sok-web-dns.sh upsert|delete <zone_id> <hostname> [ns] [ingress]}
zone_id=${2:?missing hosted zone id}
hostname=${3:?missing hostname}
ns=${4:-splunk}
ingress=${5:-splunk-web}

change_batch() { # $1=action $2=alb-dns
  cat <<JSON
{"Changes":[{"Action":"$1","ResourceRecordSet":{"Name":"$hostname","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"$2"}]}}]}
JSON
}

case "$action" in
  upsert)
    alb=""
    for i in $(seq 1 60); do
      alb=$(kubectl get ingress "$ingress" -n "$ns" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
      [ -n "$alb" ] && break
      echo "waiting for ALB address on ingress/$ingress ($i/60)…" >&2
      sleep 5
    done
    if [ -z "$alb" ]; then
      echo "ERROR: ingress/$ingress never reported a load-balancer hostname" >&2
      exit 1
    fi
    echo "Pointing $hostname -> $alb"
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$zone_id" \
      --change-batch "$(change_batch UPSERT "$alb")" >/dev/null
    echo "DNS UPSERT submitted (TTL 60s; propagation is usually seconds)."
    ;;
  delete)
    # Look up whatever the record currently points at so DELETE matches exactly.
    alb=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
      --query "ResourceRecordSets[?Name=='${hostname}.'&&Type=='CNAME'].ResourceRecords[0].Value | [0]" \
      --output text 2>/dev/null || true)
    if [ -n "$alb" ] && [ "$alb" != "None" ]; then
      aws route53 change-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --change-batch "$(change_batch DELETE "$alb")" >/dev/null
      echo "Deleted CNAME $hostname -> $alb"
    else
      echo "No CNAME $hostname to delete (already gone)."
    fi
    ;;
  *)
    echo "unknown action: $action (use upsert|delete)" >&2
    exit 2
    ;;
esac
