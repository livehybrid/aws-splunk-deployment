###############################################################################
# local-path-provisioner: dynamic hostPath PVC provisioner backed by the
# NVMe RAID-0 assembled by the EKS bootstrap (/mnt/k8s-disks).
#
# Only deployed when sok_indexer_nvme_var_storage = true. On EBS-only shapes
# (t3/m6i/c6i) this file is entirely inert.
#
# WHY local-path and not static local PVs:
#   Static `local` PVs require one pre-provisioned PV per node per claim.
#   The SOK operator creates PVCs dynamically, so static PVs would need exact
#   pre-knowledge of replica count and manual lifecycle management.
#   local-path-provisioner handles that automatically: it watches for PVCs,
#   creates a subdirectory on whichever node the pod lands on, and binds.
#
# WHY DEFAULT → /mnt/k8s-disks:
#   nodePathMap matches by node NAME, not labels. EKS node names are assigned
#   at boot so we cannot pre-populate them. Instead we set DEFAULT to the NVMe
#   mount and rely on the StorageClass allowedTopologies (splunk-sok/role=
#   indexer, WaitForFirstConsumer) to guarantee the PVC only ever binds on an
#   indexer node where /mnt/k8s-disks actually exists. The provisioner is a
#   Deployment that runs on a general node — it does not need to run on the
#   target node.
#
# DESTROY ORDERING:
#   Indexer var PVCs are deleted explicitly by the sok layer before cluster
#   teardown. Local-path volumes live on instance-store, which disappears with
#   the node group, so there are no orphaned volumes.
###############################################################################

resource "helm_release" "local_path_provisioner" {
  count = var.sok_indexer_nvme_var_storage ? 1 : 0

  name      = "local-path-provisioner"
  chart     = "${path.module}/files/charts/local-path-provisioner"
  namespace = "kube-system"
  version   = "0.0.37"

  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    # Pull through the account-layer ECR pull-through cache. 
    image = {
      repository = "${local.ecr_registry}/docker-public/rancher/local-path-provisioner"
      tag        = "v0.0.37"
    }

    helperImage = {
      repository = "${local.ecr_registry}/docker-public/library/busybox"
      tag        = "latest"
    }

    # All provisioning goes to the NVMe RAID-0. The StorageClass allowedTopologies
    # (below) ensures this class is only ever bound on indexer nodes where
    # /mnt/k8s-disks exists, so DEFAULT pointing there is safe.
    nodePathMap = [
      {
        node  = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
        paths = ["/mnt/k8s-disks"]
      }
    ]

    storageClass = {
      # Let the chart create it so the provisioner name is wired automatically.
      # We set provisionerName explicitly so our allowedTopologies SC below can
      # reference a stable, known name rather than a generated one.
      create          = false
      provisionerName = "rancher.io/local-path"
    }
  })]

  depends_on = [kubernetes_namespace_v1.splunk]
}

# StorageClass for indexer var (SmartStore cache) PVCs on NVMe nodes.
# Created separately (storageClass.create=false above) so we can set
# allowedTopologies, which the chart's SC template does not expose.
#
# allowedTopologies + WaitForFirstConsumer is load-bearing: it ensures the PVC
# only ever binds on an indexer node (splunk-sok/role=indexer) where
# /mnt/k8s-disks exists. Without this, a PVC could bind on a general node
# where DEFAULT would point at a non-existent path.
resource "kubernetes_storage_class_v1" "splunk_local_nvme" {
  count = var.sok_indexer_nvme_var_storage ? 1 : 0

  metadata {
    name = "splunk-local-nvme"
  }

  storage_provisioner    = "rancher.io/local-path"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = false # hostPath volumes cannot be resized

  allowed_topologies {
    match_label_expressions {
      key    = "splunk-sok/role"
      values = [var.sok_indexer_node_role != "" ? var.sok_indexer_node_role : "indexer"]
    }
  }

  depends_on = [helm_release.local_path_provisioner]
}
