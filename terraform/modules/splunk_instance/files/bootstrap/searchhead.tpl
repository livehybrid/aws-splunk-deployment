#!/usr/bin/env bash
# Splunk Search Head bootstrap — Amazon Linux 2023, Splunk Enterprise 10.
#
# Two modes:
#   enable_shc = true  → join a 3-member Search Head Cluster (captain
#                        elected deterministically by lowest instance ID).
#   enable_shc = false → run as a standalone SH (dev workspaces).
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
CERT_DOMAIN="$HOSTNAME.${fqdn}"
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
  "Comment": "Register SH with private DNS",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$HOSTNAME.${internal_domain}",
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

# All SHC members and the deployer share one splunk.secret (per environment)
# so encrypted values in deployer-pushed bundles decrypt on every member.
# Get-or-create in Secrets Manager (AWS CLI — boto3 isn't on the AMI); must
# be in place before first splunkd start. set +x keeps it out of the trace.
ENV_TAG=$(imds meta-data/tags/instance/environment)
SECRET_ID="/splunk/secret/shc-$ENV_TAG"
set +x
SPLUNK_SECRET=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SECRET_ID" --query SecretString --output text 2>/dev/null) || {
  SPLUNK_SECRET=$(openssl rand -base64 254 | tr -d '/+=\n' | head -c 254)
  aws secretsmanager create-secret --region "$REGION" \
    --name "$SECRET_ID" --secret-string "$SPLUNK_SECRET" >/dev/null 2>&1 \
    || SPLUNK_SECRET=$(aws secretsmanager get-secret-value --region "$REGION" \
         --secret-id "$SECRET_ID" --query SecretString --output text)
}
printf '%s' "$SPLUNK_SECRET" > /opt/splunk/etc/auth/splunk.secret
set -x
chown splunk: /opt/splunk/etc/auth/splunk.secret
chmod 400 /opt/splunk/etc/auth/splunk.secret
[ -s /opt/splunk/etc/auth/splunk.secret ] || { echo "FATAL: splunk.secret empty"; exit 1; }

/opt/splunk/bin/splunk enable boot-start \
  -systemd-managed 1 -user splunk --accept-license --answer-yes --no-prompt
systemctl start Splunkd

# Wait for splunkd's management REST to actually answer — a bare TCP check
# races a just-started splunkd that accepts and then resets connections,
# which is how `init shcluster-config` failed with "Connection reset by peer".
until curl -ks --max-time 5 https://127.0.0.1:8089/services/server/info >/dev/null; do sleep 5; done

if [ "${enable_shc}" = "true" ]; then
  # $ADMIN_PASS still set from the user-seed block above.
  # Discover SH peers by EC2 tag, ordered by InstanceId (deterministic captain).
  SH_PEERS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running" \
              "Name=tag:Name,Values=*searchhead*" \
    --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' \
    --output text | sort -k1)
  CAPTAIN_IP=$(printf '%s\n' "$SH_PEERS" | head -1 | awk '{print $2}')
  SH_HTTPS=$(printf '%s\n' "$SH_PEERS" | awk '{printf "https://%s:8089,", $2}' | sed 's/,$//')

  set +x  # keep -auth and -secret out of the trace log
  for _attempt in 1 2 3 4 5; do
    if sudo -u splunk -i /opt/splunk/bin/splunk init shcluster-config \
        -mode searchhead \
        -auth "${splunk_admin_username}:$ADMIN_PASS" \
        -mgmt_uri "https://$LOCAL_IPV4:8089" \
        -replication_port ${replication_port} \
        -replication_factor ${replication_factor} \
        -conf_deploy_fetch_url "https://deployer.${internal_domain}:${master_port}" \
        -secret "${pass4SymmKey}" \
        -shcluster_label shcluster; then
      echo "shcluster-config initialised (attempt $_attempt)"
      break
    fi
    echo "init shcluster-config failed (attempt $_attempt); retrying"
    sleep 20
  done
  set -x
  systemctl restart Splunkd

  # Captain bootstrap on the lowest-InstanceID SH only, once all peers are up.
  if [ "$LOCAL_IPV4" = "$CAPTAIN_IP" ]; then
    for ip in $(printf '%s\n' "$SH_PEERS" | awk '{print $2}'); do
      until (echo >/dev/tcp/$ip/8089) 2>/dev/null; do sleep 5; done
    done
    sleep 60
    set +x  # keep -auth out of the trace log
    sudo -u splunk -i /opt/splunk/bin/splunk bootstrap shcluster-captain \
      -servers_list "$SH_HTTPS" \
      -auth "${splunk_admin_username}:$ADMIN_PASS"
    set -x
  fi
  systemctl restart Splunkd
fi
