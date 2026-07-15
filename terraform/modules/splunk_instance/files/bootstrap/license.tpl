#!/usr/bin/env bash
# Splunk License Manager bootstrap — Amazon Linux 2023, Splunk Enterprise 10.
set -x
exec 1> /var/tmp/startup.log 2>&1

IMDS_TOKEN=$(curl -fs -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
imds() { curl -fs -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" "http://169.254.169.254/latest/$1"; }

INSTANCE_ID=$(imds meta-data/instance-id)
REGION=$(imds meta-data/placement/region)
LOCAL_IPV4=$(imds meta-data/local-ipv4)

# Pre-provisioned Elastic IP (tag:host = license).
EIP_ALLOC=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:host,Values=license" \
  --query 'Addresses[0].AllocationId' --output text)
aws ec2 associate-address --region "$REGION" \
  --allocation-id "$EIP_ALLOC" --instance-id "$INSTANCE_ID" --allow-reassociation
sleep 5

INSTANCE_NAME=$(aws ec2 describe-tags --region "$REGION" \
  --filters "Name=resource-id,Values=$${INSTANCE_ID}" "Name=key,Values=Name" \
  --query 'Tags[0].Value' --output text)
HOSTNAME=$${INSTANCE_NAME//_/-}
hostnamectl set-hostname "$HOSTNAME"

sudo -u splunk mkdir -p /opt/splunk/etc/system/local

cat > /opt/splunk/etc/system/local/deploymentclient.conf <<EOF
${deploymentclient_conf_content}
EOF
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

# License Manager runs a quiet internal pool — silence the LM stack log.
cat > /opt/splunk/etc/log-local.cfg <<EOF
category.LMStack=CRIT
EOF

# Internal role that allows licence-clients to read pool state.
cat > /opt/splunk/etc/system/local/authorize.conf <<EOF
[role_internal]
cumulativeRTSrchJobsQuota = 0
cumulativeSrchJobsQuota   = 0
dispatch_rest_to_indexers = enabled
importRoles               = user
license_edit              = enabled
license_tab               = enabled
license_view_warnings     = enabled
list_settings             = enabled
schedule_rtsearch         = disabled
srchIndexesAllowed        = _*
srchIndexesDefault        = _*
srchMaxTime               = 0
EOF

chown -R splunk: /opt/splunk

# TLS material.
mkdir -p /opt/splunk/etc/auth/customcerts/
# Key + CSR generated locally; cert signed by the internal-CA issuer Lambda.
# Fallback: self-signed if the issuer isn't deployed/reachable — in that case
# sslVerifyServerCert must stay false until every node is CA-issued.
CERT_DOMAIN="license.${fqdn}"
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

# Install the Splunk Enterprise licence from Secrets Manager.
mkdir -p /opt/splunk/etc/licenses/enterprise
aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id /monitoring/splunk/license \
  | jq -r '.SecretString' > /opt/splunk/etc/licenses/enterprise/enterprise.lic
chown -R splunk:splunk /opt/splunk/etc/licenses

# Internal DNS.
cat > /tmp/dns.json <<EOF
{
  "Comment": "Register license with private DNS",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "license.${internal_domain}",
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

# Boot-start systemd-managed and start the daemon.
/opt/splunk/bin/splunk enable boot-start \
  -systemd-managed 1 -user splunk --accept-license --answer-yes --no-prompt
systemctl start Splunkd

# Wait for splunkd's management REST (bare TCP-open races a starting splunkd).
until curl -ks --max-time 5 https://127.0.0.1:8089/services/server/info >/dev/null; do sleep 5; done
/opt/splunk/bin/splunk cmd splunkd rest --noauth POST /services/authentication/users \
  "name=internal&password=${internal_user_password}&roles=internal"
