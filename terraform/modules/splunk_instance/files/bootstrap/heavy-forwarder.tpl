#!/usr/bin/env bash
# Splunk Heavy Forwarder bootstrap — Amazon Linux 2023, Splunk Enterprise 10.
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

# Persist a stable splunk.secret per-host. Created on first boot from Secrets
# Manager (or generated and stored there if it doesn't exist) so blob-encrypted
# values survive instance recycling. AWS CLI — boto3 isn't on the AMI; set +x
# keeps the secret out of the trace log.
SECRET_ID="/splunk/secret/$HOSTNAME"
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

# Optional checkpoint EBS volume for queues/modinputs survival across replacement.
if [ "${attach_checkpoint_ebs}" == "1" ]; then
  mkdir -p /opt/splunk/var/lib/splunk/modinputs/
  CHECKPOINT_VOL=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:Name,Values=$${HOSTNAME}-checkpoint" \
    --query 'Volumes[0].VolumeId' --output text)
  CURRENT_INSTANCE=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:Name,Values=$${HOSTNAME}-checkpoint" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)
  if [ "$CURRENT_INSTANCE" != "$INSTANCE_ID" ] && [ "$CURRENT_INSTANCE" != "None" ]; then
    aws ec2 detach-volume --region "$REGION" --volume-id "$CHECKPOINT_VOL" --force
    until [ "$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$CHECKPOINT_VOL" --query 'Volumes[0].State' --output text)" = "available" ]; do sleep 3; done
  fi
  aws ec2 attach-volume --region "$REGION" \
    --volume-id "$CHECKPOINT_VOL" --instance-id "$INSTANCE_ID" --device /dev/sdf
  sleep 30
  # Nitro nvme devices: locate the checkpoint volume by tag and mount.
  for dev in /dev/nvme[1-9]n1; do
    [ -e "$dev" ] || continue
    if ! blkid "$dev" >/dev/null 2>&1; then
      if [ "${data_filesystem}" = "ext4" ]; then
        mkfs.ext4 -F "$dev"
      else
        mkfs.xfs -f "$dev"
      fi
    fi
    uuid=$(blkid -s UUID -o value "$dev")
    grep -q "$uuid" /etc/fstab || \
      echo "UUID=$uuid  /opt/splunk/var/lib/splunk/modinputs  auto  defaults,nofail  0 2" >> /etc/fstab
    break
  done
  mount -a
  chown -R splunk:splunk /opt/splunk/var/lib/splunk/modinputs/
fi

sudo -u splunk mkdir -p /opt/splunk/etc/system/local
cat > /opt/splunk/etc/system/local/deploymentclient.conf <<EOF
${deploymentclient_conf_content}
EOF
cat > /opt/splunk/etc/system/local/web.conf <<EOF
${web_conf_content}
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
cat > /opt/splunk/etc/system/local/server.conf <<EOF
${server_conf_content}
EOF
# Inputs: S2S receiver on 9997 (UFs / other Splunk forwarders) + HEC on 8088.
# TLS uses the customcerts cert generated below.
cat > /opt/splunk/etc/system/local/inputs.conf <<EOF
[splunktcp-ssl:9997]
disabled = 0
[SSL]
serverCert = /opt/splunk/etc/auth/customcerts/server_combined.pem

[http]
disabled = 0
enableSSL = 1
port = 8088
serverCert = /opt/splunk/etc/auth/customcerts/server_combined.pem
dedicatedIoThreads = 2

[http://default]
disabled = 0
indexes = main
useACK = 1
EOF
# AWS-events HEC token (EventBridge API destination → ASG/spot events).
# Fetched on-instance; useACK off because API destinations can't do ACK.
set +x
HEC_AWS_TOKEN=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id /splunk/hec/aws-events --query SecretString --output text 2>/dev/null) || HEC_AWS_TOKEN=""
if [ -n "$HEC_AWS_TOKEN" ]; then
cat >> /opt/splunk/etc/system/local/inputs.conf <<EOF

[http://aws-events]
disabled = 0
token = $HEC_AWS_TOKEN
indexes = main
sourcetype = aws:events
useACK = 0
EOF
fi
set -x
chown -R splunk: /opt/splunk

# Pre-provisioned Elastic IP if this ASG/instance is tagged with one.
EIP_ALLOC=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:Name,Values=$${INSTANCE_NAME}" \
  --query 'Addresses[0].AllocationId' --output text)
if [ "$EIP_ALLOC" != "None" ] && [ -n "$EIP_ALLOC" ]; then
  aws ec2 associate-address --region "$REGION" \
    --allocation-id "$EIP_ALLOC" --instance-id "$INSTANCE_ID" --allow-reassociation
  sleep 5
fi

mkdir -p /opt/splunk/etc/auth/customcerts/
# Key + CSR generated locally; cert signed by the internal-CA issuer Lambda.
# Fallback: self-signed if the issuer isn't deployed/reachable — in that case
# sslVerifyServerCert must stay false until every node is CA-issued.
CERT_DOMAIN="inputs.${fqdn}"
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

if [ "${enable_fips}" == "1" ]; then
  echo "" >> /opt/splunk/etc/splunk-launch.conf
  echo "SPLUNK_FIPS=1" >> /opt/splunk/etc/splunk-launch.conf
fi

/opt/splunk/bin/splunk enable boot-start \
  -systemd-managed 1 -user splunk --accept-license --answer-yes --no-prompt
systemctl start Splunkd

# Internal DNS (forwarders are externally reachable via the NLB).
cat > /tmp/dns.json <<EOF
{
  "Comment": "Register HF with private DNS",
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

# Run any extra bootstrap injected at module-call time.
if [ -x /home/ec2-user/additional-bootstrap.sh ]; then
  /home/ec2-user/additional-bootstrap.sh
fi
