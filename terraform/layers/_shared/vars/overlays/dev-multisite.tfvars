# Dev multisite overlay (DEP-3/OPS-9), the EXACT shape the S0b +
# KV-backup validation passed on: multisite (2 sites × 2 indexers, origin:2/
# total:3) + a 3-member SHC, on per-AZ node groups. Applied ON TOP of
# vars/dev.tfvars:
#
#   make -C terraform/layers/eks -f ../_shared/Makefile terraform env=dev \
#     args='-var-file=vars/overlays/dev-multisite.tfvars -auto-approve'
#   make -C terraform/layers/sok -f ../_shared/Makefile terraform env=dev \
#     args='-var-file=vars/overlays/dev-multisite.tfvars -auto-approve'
#
# or via the SOK START workflow's `overlay` input (= dev-multisite). Dev's
# committed default stays the cheap single-node single-site shape; teardown
# (SOK STOP) needs no overlay, destroy removes whatever is in state.
multisite                      = true
available_sites                = "site1,site2"
site_replication_factor_origin = 2
site_replication_factor_total  = 3
site_search_factor_origin      = 1
site_search_factor_total       = 2

enable_shc           = true
sok_indexer_replicas = 2 # per site => 4 indexers
sok_etc_storage      = "20Gi"
sok_var_storage      = "50Gi" # dev test size

# Per-AZ node groups (mirror the prod profile): site1 in 2a, site2 in 2b.
eks_node_groups = {
  general-a = { instance_type = "t3.xlarge", desired = 2, min = 2, max = 3, availability_zone = "eu-west-2a" }
  general-b = { instance_type = "t3.xlarge", desired = 1, min = 1, max = 2, availability_zone = "eu-west-2b" }
}
