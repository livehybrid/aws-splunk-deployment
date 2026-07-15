#!/usr/bin/env bash
# Splunk Monitoring Console bootstrap — Amazon Linux 2023, Splunk Enterprise 10.
#
# MC config (peer registration etc.) is done by an operator after first boot
# via `splunk add monitoring-console-asset` — this bootstrap just stands up a
# vanilla Splunk daemon.
set -x
exec 1> /var/tmp/startup.log 2>&1

IMDS_TOKEN=$(curl -fs -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
imds() { curl -fs -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" "http://169.254.169.254/latest/$1"; }

INSTANCE_ID=$(imds meta-data/instance-id)
REGION=$(imds meta-data/placement/region)
LOCAL_IPV4=$(imds meta-data/local-ipv4)

INSTANCE_NAME=$(aws ec2 describe-tags --region "$REGION" \
  --filters "Name=resource-id,Values=$${INSTANCE_ID}" "Name=key,Values=Name" \
  --query 'Tags[0].Value' --output text)
HOSTNAME=$${INSTANCE_NAME//_/-}
hostnamectl set-hostname "$HOSTNAME"

sudo -u splunk mkdir -p /opt/splunk/etc/system/local
cat > /opt/splunk/etc/system/local/web.conf <<EOF
${web_conf_content}
EOF
cat > /opt/splunk/etc/system/local/server.conf <<EOF
${server_conf_content}
EOF
# Admin seed — password fetched from Secrets Manager on-instance so it never
# enters user-data, Terraform state, or the set -x trace.
set +x
ADMIN_PASS=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id /monitoring/splunk/password --query SecretString --output text)
cat > /opt/splunk/etc/system/local/user-seed.conf <<EOF
[user_info]
USERNAME = ${splunk_admin_username}
PASSWORD = $ADMIN_PASS
EOF
set -x
chown -R splunk: /opt/splunk

# TLS material.
mkdir -p /opt/splunk/etc/auth/customcerts/
# Key + CSR generated locally; cert signed by the internal-CA issuer Lambda.
# Fallback: self-signed if the issuer isn't deployed/reachable — in that case
# sslVerifyServerCert must stay false until every node is CA-issued.
CERT_DOMAIN="mc.${fqdn}"
CCD=/opt/splunk/etc/auth/customcerts
ENV_TAG=$(imds meta-data/tags/instance/environment)
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$CCD/server.key" -out "$CCD/server.csr" \
  -subj  "/CN=$CERT_DOMAIN" \
  -addext "subjectAltName=DNS:$CERT_DOMAIN,DNS:*.${fqdn},DNS:*.${internal_domain}"
if aws lambda invoke --region "$REGION" \
     --function-name "splunk-cert-issuer-$ENV_TAG" \
     --cli-binary-format raw-in-base64-out \
     --payload "$(jq -n --rawfile csr "$CCD/server.csr" '{csr: $csr}')" \
     /tmp/issued-cert.json >/dev/null 2>&1 \
   && jq -e '.certificate' /tmp/issued-cert.json >/dev/null 2>&1; then
  jq -r '.certificate' /tmp/issued-cert.json > "$CCD/server.crt"
  jq -r '.ca'          /tmp/issued-cert.json > "$CCD/ca.crt"
else
  echo "WARN: cert issuer unavailable; using self-signed cert"
  if [ "${ssl_verify}" = "true" ]; then
    echo "FATAL: sslVerifyServerCert=true requires a CA-issued cert; failing bootstrap so the ASG replaces this instance"
    exit 1
  fi
  openssl req -x509 -key "$CCD/server.key" -out "$CCD/server.crt" -days 365 \
    -subj  "/CN=$CERT_DOMAIN" \
    -addext "subjectAltName=DNS:$CERT_DOMAIN,DNS:*.${fqdn},DNS:*.${internal_domain}"
  aws s3 cp "s3://${s3_pki_bucket}/ca/${ca_name}.crt" "$CCD/ca.crt" --region "$REGION"
fi
cp "$CCD/ca.crt" /opt/splunk/etc/auth/cacert.pem
cat "$CCD/server.crt" "$CCD/server.key" "$CCD/ca.crt" > "$CCD/server_combined.pem"
chown -R splunk:splunk "$CCD/"

# Internal DNS.
cat > /tmp/dns.json <<EOF
{
  "Comment": "Register MC with private DNS",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "mc.${internal_domain}",
      "Type": "A",
      "TTL": 90,
      "ResourceRecords": [{ "Value": "$LOCAL_IPV4" }]
    }
  }]
}
EOF
aws route53 change-resource-record-sets --region "$REGION" \
  --hosted-zone-id ${private_dns_zone} \
  --change-batch file:///tmp/dns.json

/opt/splunk/bin/splunk enable boot-start \
  -systemd-managed 1 -user splunk --accept-license --answer-yes --no-prompt
systemctl start Splunkd

# Register every running cluster node as a distributed-search peer. Written
# to disk and idempotent (remove+add re-exchanges distServerKeys trust), so
# it runs at MC boot AND can be re-run after any node recycle via
# `make mc-register` — a replacement instance keeps its DNS name but loses
# the MC's trusted key, so re-adding is required.
cat > /opt/splunk/bin/mc-register-peers.sh <<'MCEOF'
#!/bin/bash
# Reconcile MC distributed-search peers + DMC groups against EC2 reality.
# Runs from a systemd timer: convergent, idempotent, status-aware —
#   missing peer            -> add
#   peer not Up (recycled)  -> remove + add (re-exchanges trust keys)
#   peer gone from EC2      -> remove (scale-in needs no teardown hooks)
# then rewrites role-correct dmc_group_* memberships and (on change)
# rebuilds the MC assets. Replaces the UI Settings->MC->Apply flow.
set -e
T=$(curl -fs -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -fs -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/placement/region)
ENVT=$(curl -fs -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/tags/instance/environment)
DOM="$ENVT.splunk.internal"
ADMIN=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id /monitoring/splunk/password --query SecretString --output text)
until curl -ks --max-time 5 https://127.0.0.1:8089/services/server/info >/dev/null; do sleep 5; done
B="https://127.0.0.1:8089"
AUTH="${splunk_admin_username}:$ADMIN"
SPL() { sudo -u splunk /opt/splunk/bin/splunk "$@" -auth "$AUTH"; }

names_for_role() {
  aws ec2 describe-instances --region "$REGION" \
    --filters Name=tag:project,Values=splunk "Name=tag:environment,Values=$ENVT" \
              "Name=tag:role,Values=$1" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value]' \
    --output text | tr "\t" "\n" | tr "_" "-" | grep -v '^None$' | grep -v '^$' || true
}

# Desired peers: role singletons by service DNS name, SH/HF by hostname.
WANT="manager.$DOM:8089 license.$DOM:8089 deployer.$DOM:8089"
SHS=""
for n in $(names_for_role searchhead); do WANT="$WANT $n.$DOM:8089"; SHS="$SHS $n.$DOM:8089"; done
for n in $(names_for_role heavy-forwarder); do WANT="$WANT $n.$DOM:8089"; done

# Current peers + status from the MC itself.
CUR=$(curl -ks -u "$AUTH" "$B/services/search/distributed/peers?output_mode=json&count=0" \
  | jq -r '.entry[] | "\(.name) \(.content.status)"' 2>/dev/null || true)

CHANGES=0
for p in $WANT; do
  st=$(echo "$CUR" | awk -v p="$p" '$1==p {print $2}')
  if [ -z "$st" ]; then
    echo "adding $p"
    SPL add search-server "https://$p" -remoteUsername "${splunk_admin_username}" -remotePassword "$ADMIN" \
      >/dev/null 2>&1 && CHANGES=$((CHANGES+1)) || echo "WARN: add failed for $p (not up yet? next cycle)"
  elif [ "$st" != "Up" ]; then
    echo "re-adding $p (status: $st)"
    SPL remove search-server "https://$p" >/dev/null 2>&1 || true
    SPL add search-server "https://$p" -remoteUsername "${splunk_admin_username}" -remotePassword "$ADMIN" \
      >/dev/null 2>&1 && CHANGES=$((CHANGES+1)) || echo "WARN: re-add failed for $p"
  fi
done
# Prune peers that no longer exist in EC2.
for cur in $(echo "$CUR" | awk '{print $1}'); do
  case " $WANT " in *" $cur "*) ;; *)
    echo "pruning stale peer $cur"
    SPL remove search-server "https://$cur" >/dev/null 2>&1 && CHANGES=$((CHANGES+1)) || true ;;
  esac
done

# DMC groups: rewritten every run (cheap, idempotent).
post() { local path=$1; shift; curl -ks -u "$AUTH" -X POST "$B$path" "$@" -o /dev/null -w "%%{http_code}"; }
group() {
  local name=$1 dflt=$2; shift 2
  local args=(-d "default=$dflt")
  for m in "$@"; do args+=(--data-urlencode "member=$m"); done
  curl -ks -u "$AUTH" -X POST "$B/services/search/distributed/groups" -d "name=$name" -o /dev/null || true
  RC=$(post "/services/search/distributed/groups/$name/edit" "$${args[@]}")
  [ "$RC" = "200" ] || echo "WARN: group $name -> HTTP $RC"
}
group dmc_group_cluster_master    false "manager.$DOM:8089"
group dmc_group_license_master    false "license.$DOM:8089"
group dmc_group_deployment_server false "manager.$DOM:8089"
group dmc_group_shc_deployer      false "deployer.$DOM:8089"
group dmc_group_search_head       false "localhost:localhost" $SHS
group dmc_group_kv_store          false $SHS

GUID=$(curl -ks -u "$AUTH" "$B/services/search/distributed/peers?output_mode=json&count=0" \
  | jq -r '.entry[] | select(.name|startswith("manager.")) | .content.cluster_ids[0] // empty' | head -1)
[ -z "$GUID" ] && GUID=$(curl -ks -u "$AUTH" \
  "https://manager.$DOM:8089/services/cluster/config?output_mode=json" \
  | jq -r '.entry[0].content.guid // empty')
if [ -n "$GUID" ]; then
  group "dmc_indexerclustergroup_$GUID" false "manager.$DOM:8089" $SHS
else
  echo "WARN: no cluster GUID yet; skipping indexerclustergroup"
fi

if [ "$CHANGES" -gt 0 ]; then
  ALLPEERS=$(echo "$WANT" | tr " " "\n" | paste -sd, -)
  RC=$(post "/servicesNS/nobody/splunk_monitoring_console/configs/conf-splunk_monitoring_console_assets/settings" \
    -d disabled=false --data-urlencode "configuredPeers=$ALLPEERS")
  RC2=$(post "/servicesNS/nobody/splunk_monitoring_console/configs/conf-app/install" -d is_configured=1)
  RC3=$(post "/servicesNS/nobody/splunk_monitoring_console/saved/searches/DMC%20Asset%20-%20Build%20Full/dispatch" -d trigger_actions=1)
  echo "applied $CHANGES change(s); assets=$RC configured=$RC2 rebuild=$RC3"
else
  echo "no changes; peers converged"
fi
MCEOF
chmod 750 /opt/splunk/bin/mc-register-peers.sh

# Reconciliation timer: first run after boot (gives SHC time to form),
# then every 10 min — covers slow cold-starts, recycles, scale in/out.
cat > /etc/systemd/system/mc-register-peers.service <<'UNITEOF'
[Unit]
Description=Reconcile Splunk MC distributed-search peers
[Service]
Type=oneshot
ExecStart=/opt/splunk/bin/mc-register-peers.sh
UNITEOF
cat > /etc/systemd/system/mc-register-peers.timer <<'UNITEOF'
[Unit]
Description=Periodic Splunk MC peer reconciliation
[Timer]
OnBootSec=4min
OnUnitActiveSec=10min
RandomizedDelaySec=30
[Install]
WantedBy=timers.target
UNITEOF
systemctl daemon-reload
systemctl enable --now mc-register-peers.timer

