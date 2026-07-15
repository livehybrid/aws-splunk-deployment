###############################################################################
# sok-foundation — the PERSISTENT per-workspace AWS foundation the SOK path
# needs but the account layer cannot provide for dev.
#
# Why this layer exists:
#   Dev and prod share one AWS account. The full account layer cannot apply a
#   second time here — it has fixed-name resources (alias/pki-key, the
#   default-{a,b,c} subnets, Route53 zones) that would collide with the live
#   prod estate. So the small slice of account foundation the SOK deployment
#   actually needs — the SmartStore bucket + its KMS key (and, later, the K4
#   apps bucket) — is carved out here, env-suffixed so nothing collides.
#
# Lifecycle: apply ONCE per workspace; this layer is NEVER part of the nightly
# eks/sok destroy/recreate cycle. It holds the SmartStore data that is the
# source of truth across nightly cycles (see docs/kubernetes-sok-plan.md §5),
# so the KMS key is prevent_destroy and the bucket must outlive every teardown.
#
# Own state key (NEVER reuse another layer's): sok-foundation/terraform.tfstate.
# Reads no remote state; the sok layer discovers these resources by naming
# convention (livehybrid-splunk-<env>-splunk-smartstore-<env> /
# alias/splunk-smartstore-<env>-key), matching the account layer exactly.
###############################################################################

terraform {
  backend "s3" {
    key     = "sok-foundation/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
