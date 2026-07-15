#!/usr/bin/env bash
# Install Splunk Enterprise on Amazon Linux 2023.
# Run as root.
set -euo pipefail

# Dedicated splunk user, home /home/splunk, primary group splunk.
useradd \
  --create-home \
  --home-dir /home/splunk \
  --shell /bin/bash \
  --user-group \
  --comment "Splunk dedicated user" \
  splunk

# Convenience aliases for operator SSH-via-SSM sessions.
tee -a /home/splunk/.bashrc >/dev/null <<'EOF'
alias ll='ls -lrt'
export PATH=$PATH:/opt/splunk/bin
cd /opt/splunk/etc
EOF
chown splunk:splunk /home/splunk/.bashrc

# RPM install. /opt/splunk is created by the package.
# Splunk's 1.5 GB RPM is staged in /var/tmp (disk-backed) rather than /tmp,
# which AL2023 mounts as tmpfs.
dnf install -y /var/tmp/splunk.rpm
chown -R splunk:splunk /opt/splunk

# Do NOT boot or accept the licence here — first-boot user-data does that
# after writing role-specific server.conf, with the correct splunk user.
