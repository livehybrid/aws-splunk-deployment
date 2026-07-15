#!/usr/bin/env bash
# Splunk Indexer bootstrap — Amazon Linux 2023, Splunk Enterprise 10.
#
# Indexer cluster membership is configured in server.conf (mode = slave,
# manager_uri = …) before splunkd starts. Index definitions and SmartStore
# remote_store config come from the cluster bundle the Cluster Manager
# distributes, NOT from this script.
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

# Splunk local config (cluster mode = slave is in server_conf).
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
cat > /opt/splunk/etc/system/local/outputs.conf <<EOF
[indexAndForward]
index = true
EOF
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
  "Comment": "Register indexer with private DNS",
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

# SmartStore cache: single gp3 EBS volume tagged "<hostname>-cache" attached
# to /opt/splunk/var/lib/splunk. The volume is created in the cluster layer.
mkdir -p /opt/splunk/var/lib/splunk
CACHE_VOL=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:Name,Values=$${HOSTNAME}-cache" \
  --query 'Volumes[0].VolumeId' --output text)
if [ "$CACHE_VOL" != "None" ] && [ -n "$CACHE_VOL" ]; then
  aws ec2 attach-volume --region "$REGION" \
    --volume-id "$CACHE_VOL" --instance-id "$INSTANCE_ID" --device /dev/sdf
  # Wait for the kernel to surface the device under its Nitro nvme name.
  for _ in $(seq 1 30); do
    for dev in /dev/nvme[1-9]n1; do
      [ -e "$dev" ] || continue
      vol_id=$(nvme id-ctrl -v "$dev" 2>/dev/null | awk -F: '/vol[0-9a-f]+/{print $2; exit}' | tr -d ' ')
      if [ "vol-$${vol_id#vol}" = "$CACHE_VOL" ] || [ "$vol_id" = "$${CACHE_VOL#vol-}" ]; then
        CACHE_DEV="$dev"
        break 2
      fi
    done
    sleep 2
  done
  CACHE_DEV=$${CACHE_DEV:-/dev/nvme1n1}
  if ! blkid "$CACHE_DEV" >/dev/null 2>&1; then
    if [ "${data_filesystem}" = "ext4" ]; then
      mkfs.ext4 -F "$CACHE_DEV"
    else
      mkfs.xfs -f "$CACHE_DEV"
    fi
  fi
  uuid=$(blkid -s UUID -o value "$CACHE_DEV")
  grep -q "$uuid" /etc/fstab || \
    echo "UUID=$uuid  /opt/splunk/var/lib/splunk  auto  defaults,nofail  0 2" >> /etc/fstab
  mount -a
fi
# /opt/splunk/var (and the freshly-mounted lib/splunk under it) must be
# splunk-owned before `splunk enable boot-start`, otherwise splunkd can't
# create /opt/splunk/var/log/splunk/first_install.log and systemd unit
# install fails.
mkdir -p /opt/splunk/var/log /opt/splunk/var/lib/splunk
chown -R splunk:splunk /opt/splunk/var

# Size the SmartStore cache to the volume actually mounted (90%, with 5 GB
# eviction padding) so dev and prod volume sizes both get sane limits instead
# of splunkd's defaults filling the disk.
CACHE_MB=$(df -m /opt/splunk/var/lib/splunk | awk 'NR==2 {print int($2*90/100)}')
cat >> /opt/splunk/etc/system/local/server.conf <<EOF

[cachemanager]
max_cache_size = $CACHE_MB
eviction_padding = 5120
EOF

# On a cold full-cluster start the indexers tend to boot before the CM has
# registered manager.<internal_domain>, so splunkd would sit logging "cannot
# reach manager" until its own retries catch up. Wait (cap ~10 min) for the
# record to exist and 8089 to answer, then start clean. getent uses the VPC
# resolver directly; dig/bind-utils aren't on the AL2023 minimal image.
for _ in $(seq 1 120); do
  if getent hosts manager.${internal_domain} >/dev/null \
     && (echo >/dev/tcp/manager.${internal_domain}/8089) 2>/dev/null; then
    break
  fi
  sleep 5
done

# Boot-start and start the daemon. Index/cluster join happens once splunkd
# reaches out to the CM with the configured manager_uri.
/opt/splunk/bin/splunk enable boot-start \
  -systemd-managed 1 -user splunk --accept-license --answer-yes --no-prompt
systemctl start Splunkd
