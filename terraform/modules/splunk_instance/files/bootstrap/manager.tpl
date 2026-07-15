#!/usr/bin/env bash
# Splunk Cluster Manager bootstrap — Amazon Linux 2023, Splunk Enterprise 10.
set -x
exec 1> /var/tmp/startup.log 2>&1

# IMDSv2 token for metadata calls.
IMDS_TOKEN=$(curl -fs -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
imds() { curl -fs -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" "http://169.254.169.254/latest/$1"; }

INSTANCE_ID=$(imds meta-data/instance-id)
REGION=$(imds meta-data/placement/region)
LOCAL_IPV4=$(imds meta-data/local-ipv4)

# Allocate the pre-provisioned Elastic IP (tag:host = manager).
EIP_ALLOC=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:host,Values=manager" \
  --query 'Addresses[0].AllocationId' --output text)
aws ec2 associate-address --region "$REGION" \
  --allocation-id "$EIP_ALLOC" \
  --instance-id "$INSTANCE_ID" \
  --allow-reassociation
sleep 5

# Hostname from the EC2 Name tag (used in DNS records below).
INSTANCE_NAME=$(aws ec2 describe-tags --region "$REGION" \
  --filters "Name=resource-id,Values=$${INSTANCE_ID}" "Name=key,Values=Name" \
  --query 'Tags[0].Value' --output text)
HOSTNAME=$${INSTANCE_NAME//_/-}
hostnamectl set-hostname "$HOSTNAME"

# Splunk local config.
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

# Optional SAML to an external IdP (e.g. Azure AD). Skipped when
# sso_admin_ad_guid is unset.
if [ -n "${sso_admin_ad_guid}" ]; then
  cat > /opt/splunk/etc/system/local/authentication.conf <<EOF
[roleMap_SAML]
admin = ${sso_admin_ad_guid}

[authentication]
authSettings = saml
authType     = SAML

[saml]
entityId               = https://manager.ui.${fqdn}/
fqdn                   = https://manager.ui.${fqdn}/
idpCertPath            = idpCert.pem
sslKeysfile            = /opt/splunk/etc/auth/customcerts/server_combined.pem
replicateCertificates  = true
signAuthnRequest       = true
signedAssertion        = true
sloBinding             = HTTP-POST
ssoBinding             = HTTP-POST

[authenticationResponseAttrMap_SAML]
mail     = http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name
realName = http://schemas.microsoft.com/identity/claims/displayname
role     = http://schemas.microsoft.com/ws/2008/06/identity/claims/groups
EOF

  mkdir -p /opt/splunk/etc/auth/idpCerts/
  aws secretsmanager get-secret-value --region "$REGION" \
    --secret-id /splunk/secret/idpCert \
    | jq -r '.SecretString' > /opt/splunk/etc/auth/idpCerts/idpCert.pem
  chown -R splunk: /opt/splunk/etc/auth/idpCerts/
fi

chown -R splunk: /opt/splunk

# TLS material from the internal CA Lambda + root CA from S3.
mkdir -p /opt/splunk/etc/auth/customcerts/
# Key + CSR generated locally; cert signed by the internal-CA issuer Lambda.
# Fallback: self-signed if the issuer isn't deployed/reachable — in that case
# sslVerifyServerCert must stay false until every node is CA-issued.
CERT_DOMAIN="manager.${fqdn}"
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

# Register the CM in private and public DNS.
cat > /tmp/dns-private.json <<EOF
{
  "Comment": "Register manager with private DNS",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "manager.${internal_domain}",
      "Type": "A",
      "TTL": 90,
      "ResourceRecords": [{ "Value": "$LOCAL_IPV4" }]
    }
  }]
}
EOF
aws route53 change-resource-record-sets --region "$REGION" \
  --hosted-zone-id ${private_dns_zone} \
  --change-batch file:///tmp/dns-private.json

# No public DNS registration: manager.${fqdn} is a CNAME to the splunk-web
# ALB (Terraform-managed, host-header routed). Registering an A record here
# would conflict with it.

# SmartStore cluster bundle — the CM distributes this to every peer.
if [ -n "${smartstore_bucket}" ]; then
  mkdir -p /opt/splunk/etc/manager-apps/_cluster/local/
  cat > /opt/splunk/etc/manager-apps/_cluster/local/indexes.conf <<EOF
[volume:remote_store]
storageType            = remote
path                   = s3://${smartstore_bucket}/
remote.s3.encryption   = sse-kms
remote.s3.kms.key_id   = ${smartstore_kms_arn}
remote.s3.auth_region  = ${region}
# Global [sslConfig] sslVerifyServerCert=true would validate AWS endpoints
# against the internal cluster CA and fail; S3/KMS verify against the OS
# trust store instead (still full verification, correct anchor).
remote.s3.sslVerifyServerCert     = true
remote.s3.sslRootCAPath           = /etc/pki/tls/certs/ca-bundle.crt
remote.s3.kms.sslVerifyServerCert = true
remote.s3.kms.sslRootCAPath       = /etc/pki/tls/certs/ca-bundle.crt

[default]
remotePath = volume:remote_store/\$_index_name
EOF
  chown -R splunk:splunk /opt/splunk/etc/manager-apps/
fi

# Splunk boot-start under systemd, owned by splunk user.
/opt/splunk/bin/splunk enable boot-start \
  -systemd-managed 1 \
  -user splunk \
  --accept-license --answer-yes --no-prompt
systemctl start Splunkd

# Apps-from-git sync: written to disk as a reusable script so a running CM
# can re-sync without a recycle (`make deploy-apps` invokes it via SSM).
# Bootstrap runs it once and restarts splunkd on success.
if [ -n "${apps_git_repo}" ]; then
  cat > /opt/splunk/bin/sync-apps-from-git.sh <<'SYNCEOF'
#!/bin/bash
# Sync Splunk apps from git (Cluster Manager). Safe to re-run: missing/empty
# repo dirs never delete live apps; _cluster (bootstrap-written SmartStore
# config) is protected; etc/apps is merge-only (built-ins preserved);
# #splunksecret:<id># placeholders resolve from Secrets Manager.
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
sync_dir() {
  local d=$1; shift
  if [ -d "$CHECKOUT/$d" ] && [ -n "$(ls -A "$CHECKOUT/$d")" ]; then
    mkdir -p /opt/splunk/etc/$d
    rsync -a "$@" "$CHECKOUT/$d/" /opt/splunk/etc/$d/
  else
    echo "WARN: $d missing or empty in apps repo; leaving live $d untouched"
  fi
}
sync_dir manager-apps --delete --exclude=_cluster
sync_dir deployment-apps --delete
sync_dir apps
grep -Rl splunksecret /opt/splunk/etc/manager-apps /opt/splunk/etc/deployment-apps /opt/splunk/etc/apps 2>/dev/null \
  | xargs --no-run-if-empty sed -i -E \
    "s/(.*)#splunksecret\:([^#]+)#(.*)/echo \"\\1\$(aws secretsmanager get-secret-value --region $REGION --secret-id \\2 | jq -r .SecretString)\\3\"/eg"
chown -R splunk:splunk /opt/splunk/etc/manager-apps /opt/splunk/etc/deployment-apps /opt/splunk/etc/apps 2>/dev/null || true
echo "apps sync complete"
SYNCEOF
  chmod 750 /opt/splunk/bin/sync-apps-from-git.sh
  if /opt/splunk/bin/sync-apps-from-git.sh; then
    systemctl restart Splunkd
  else
    echo "WARN: apps sync failed; continuing without apps."
  fi
fi
