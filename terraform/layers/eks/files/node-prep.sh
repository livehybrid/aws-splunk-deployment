#!/bin/bash
# Splunk node prep (runs before nodeadm on AL2023 EKS nodes).
#
# THP: Splunk documents >= 30% indexing/search degradation with transparent
# hugepages enabled, and the operator does not manage node OS settings,
# so it is disabled here, persistently (survives reboots via systemd unit).
set -euo pipefail

cat > /etc/systemd/system/disable-thp.service << 'UNIT'
[Unit]
Description=Disable transparent hugepages (Splunk)
After=sysinit.target local-fs.target
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now disable-thp.service

# Splunk-recommended ulimits for the container runtime path. containerd on
# AL2023 already defaults NOFILE high; NPROC is raised for search storms.
mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/containerd.service.d/99-splunk-limits.conf << 'LIMITS'
[Service]
LimitNOFILE=1048576
LimitNPROC=524288
LIMITS
systemctl daemon-reload
