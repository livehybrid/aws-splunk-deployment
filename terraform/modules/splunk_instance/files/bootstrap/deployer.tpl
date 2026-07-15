#!/usr/bin/env bash
# Splunk SHC Deployer bootstrap — Amazon Linux 2023, Splunk Enterprise 10.
#
# Stateless beyond the git clone — SHC apps live under
# /opt/splunk/etc/shcluster/apps and get pushed to the SHC via
# `splunk apply shcluster-bundle`.
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
CERT_DOMAIN="deployer.${fqdn}"
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
  "Comment": "Register deployer with private DNS",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "deployer.${internal_domain}",
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

# Share the SHC splunk.secret (per environment) so encrypted values in the
# bundles this deployer pushes decrypt on every SHC member. Get-or-create in
# Secrets Manager (AWS CLI — boto3 isn't on the AMI); must be in place before
# first splunkd start. set +x keeps it out of the trace.
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

# Apps-from-git sync: written to disk as a reusable script so a running
# deployer can re-sync without a recycle (`make deploy-apps` via SSM).
if [ -n "${apps_git_repo}" ]; then
  cat > /opt/splunk/bin/sync-apps-from-git.sh <<'SYNCEOF'
#!/bin/bash
# Sync SHC apps from git (Deployer). Safe to re-run: missing/empty repo
# dirs never delete the live staging; #splunksecret:<id># placeholders
# resolve from Secrets Manager.
set -e
T=$(curl -fs -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -fs -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/placement/region)
command -v rsync >/dev/null 2>&1 || dnf install -y rsync
GIT_TOKEN=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id /git/login --query SecretString --output text)
CHECKOUT=/var/tmp/splunk-apps
rm -rf "$CHECKOUT"
CLONED=false
for _try in 1 2 3; do
  if git clone --depth=1 "https://x-access-token:$GIT_TOKEN@${apps_git_repo}" "$CHECKOUT" 2>&1 \
       | sed -E 's/x-access-token:[^@]+@/x-access-token:REDACTED@/g'; then
    CLONED=true; break
  fi
  rm -rf "$CHECKOUT"; sleep 15
done
$CLONED || { echo "ERROR: apps repo clone failed"; exit 1; }
git -C "$CHECKOUT" checkout main 2>/dev/null || git -C "$CHECKOUT" checkout master 2>/dev/null || true
mkdir -p /opt/splunk/etc/shcluster/apps
if [ -d "$CHECKOUT/shcluster/apps" ] && [ -n "$(ls -A "$CHECKOUT/shcluster/apps")" ]; then
  rsync -a --delete "$CHECKOUT/shcluster/apps/" /opt/splunk/etc/shcluster/apps/
elif [ -d "$CHECKOUT/apps" ] && [ -n "$(ls -A "$CHECKOUT/apps")" ]; then
  rsync -a --delete "$CHECKOUT/apps/" /opt/splunk/etc/shcluster/apps/
else
  echo "WARN: no shcluster/apps or apps content in repo; leaving staging untouched"
fi
grep -Rl splunksecret /opt/splunk/etc/shcluster/ 2>/dev/null \
  | xargs --no-run-if-empty sed -i -E \
    "s/(.*)#splunksecret\:([^#]+)#(.*)/echo \"\\1\$(aws secretsmanager get-secret-value --region $REGION --secret-id \\2 | jq -r .SecretString)\\3\"/eg"
chown -R splunk:splunk /opt/splunk/etc/shcluster
echo "shcluster apps sync complete"
SYNCEOF
  chmod 750 /opt/splunk/bin/sync-apps-from-git.sh
  /opt/splunk/bin/sync-apps-from-git.sh || echo "WARN: apps sync failed; continuing without apps."
fi
