#!/bin/bash
# Assemble NVMe instance-store disks into a RAID-0 at /mnt/k8s-disks.
# Runs as a cloudinit_pre_nodeadm script on nvme_local_storage=true node groups
# (e.g. i7i.*) before nodeadm/kubelet start, so local-path-provisioner finds the
# mount ready when it provisions PVCs.
#
# WHY NOT localStorage: RAID0 (NodeConfig): that strategy mounts the RAID as the
# containerd/kubelet root filesystem. The PVC host path (/mnt/k8s-disks) then
# falls back to a directory on the root EBS (~20 GB), not the RAID.
#
# Device discovery: lsblk MODEL column is "Amazon EC2 NVMe Instance Storage" for
# instance-store and "Amazon Elastic Block Store" for EBS on AL2023. We use this
# rather than nvme-cli (nvme id-ctrl) which is not installed by default on AL2023.
# Only bare disk devices (not partitions) are selected.
set -uo pipefail

MOUNT=/mnt/k8s-disks

# Idempotent: skip if already mounted (node reboot after fstab is written).
if mountpoint -q "$MOUNT" 2>/dev/null; then
  echo "nvme-raid: $MOUNT already mounted, nothing to do"
  exit 0
fi

# Collect instance-store NVMe block devices using lsblk MODEL column.
# AL2023 sets MODEL="Amazon EC2 NVMe Instance Storage" for instance-store disks.
DEVS=()
while IFS= read -r dev; do
  DEVS+=("/dev/$dev")
done < <(lsblk -d -o NAME,MODEL --noheadings | awk '/Amazon EC2 NVMe Instance Storage/{print $1}')

N=${#DEVS[@]}
if [[ $N -eq 0 ]]; then
  echo "nvme-raid: no instance-store devices found, skipping"
  exit 0
fi

echo "nvme-raid: assembling RAID-0 from $N device(s): ${DEVS[*]}"

# mdadm is present on AL2023; install it if somehow absent.
if ! command -v mdadm &>/dev/null; then
  dnf install -y -q mdadm
fi

mdadm --create /dev/md0 --level=0 --raid-devices="$N" \
  --force --run "${DEVS[@]}"

mkfs.xfs -f /dev/md0

mkdir -p "$MOUNT"
mount /dev/md0 "$MOUNT"

# Persist across reboots.
UUID=$(blkid -s UUID -o value /dev/md0)
echo "UUID=$UUID $MOUNT xfs defaults,nofail 0 2" >> /etc/fstab

echo "nvme-raid: $MOUNT ready ($(df -h "$MOUNT" | awk 'NR==2{print $2}'))"
