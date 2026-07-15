###############################################################################
# StorageClasses for the Splunk etc/var PVCs.
#
# - WaitForFirstConsumer is load-bearing: it provisions each EBS volume in the
#   AZ of the pod that claims it. Without it, zone-pinned multisite indexer
#   pods wedge on cross-AZ volumes (SOK issue #1152).
# - reclaimPolicy Delete + the sok layer deleting PVCs before cluster destroy
#   is what keeps the nightly stop from orphaning EBS volumes.
# - data_volume_filesystem (xfs|ext4, shared tfvars knob) picks which class
#   the Splunk CRs reference; both exist so the toggle is a CR field change.
###############################################################################

resource "kubernetes_storage_class_v1" "splunk_gp3" {
  for_each = toset(["xfs", "ext4"])

  metadata {
    name = "splunk-gp3-${each.key}"
    annotations = {
      # xfs is the estate default (matches data_volume_filesystem default).
      "storageclass.kubernetes.io/is-default-class" = each.key == "xfs" ? "true" : "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type                        = "gp3"
    "csi.storage.k8s.io/fstype" = each.key
    encrypted                   = "true"
  }

  depends_on = [module.eks]
}
