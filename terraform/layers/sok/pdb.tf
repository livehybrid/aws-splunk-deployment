###############################################################################
# PodDisruptionBudgets — the operator creates none. Keep >=1 indexer available
# per site during voluntary disruptions (node drain/upgrade) so an eviction
# can't breach RF/SF. Also an SHC PDB (minAvailable 2 of 3) in prod.
#
# ⚠ Only create a PDB when the target set has >1 replica: a minAvailable=1 PDB
# over a SINGLE pod makes it un-evictable and blocks node drains (single-indexer
# dev, and any 1-replica set). The nightly destroy bypasses PDBs anyway.
#
# ⚠ Gap: terminationGracePeriodSeconds / preStop are NOT exposed on the v4 CRs;
# the operator runs `splunk offline` on scale-DOWN (graceful decommission), and
# the K3 probe overrides give busy pods a ~20-min shutdown budget.
###############################################################################

# Single-site (dev): one PDB over the single IndexerCluster's peers (only when
# it has >1 replica — so a 1-indexer dev gets none).
resource "kubernetes_pod_disruption_budget_v1" "indexers" {
  count = !var.multisite && var.sok_indexer_replicas > 1 ? 1 : 0

  metadata {
    name      = "splunk-idxc-indexer-pdb"
    namespace = local.namespace
  }
  spec {
    min_available = 1
    selector {
      match_labels = { "app.kubernetes.io/instance" = "splunk-idxc-indexer" }
    }
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

# Multisite (prod): one PDB per site, keeping >=1 peer of that site available.
resource "kubernetes_pod_disruption_budget_v1" "indexers_site" {
  for_each = var.sok_indexer_replicas > 1 ? local.sites : {}

  metadata {
    name      = "splunk-idxc-${each.key}-indexer-pdb"
    namespace = local.namespace
  }
  spec {
    min_available = 1
    selector {
      match_labels = { "app.kubernetes.io/instance" = "splunk-idxc-${each.key}-indexer" }
    }
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

# SHC (prod): keep a quorum (2 of 3) available during voluntary disruptions.
resource "kubernetes_pod_disruption_budget_v1" "shc" {
  count = var.enable_shc ? 1 : 0

  metadata {
    name      = "splunk-shc-search-head-pdb"
    namespace = local.namespace
  }
  spec {
    min_available = 2
    selector {
      match_labels = { "app.kubernetes.io/instance" = "splunk-shc-search-head" }
    }
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}
