###############################################################################
# EC2-vs-SOK deployment model gating.
#
# deployment_model = "ec2"  -> this layer runs the full Splunk core (default).
# deployment_model = "sok"  -> the Splunk core (CM, indexers, SHs, LM, MC,
#   deployer) lives in the eks + sok layers instead; this layer keeps only the
#   heavy-forwarder edge tier (when sok_edge_on_ec2 = true), because SOK has
#   no HF/DS CRD.
#
# Every core resource in this layer consumes local.enable_splunk_* below
# instead of the raw variables, so one flag flip retires the EC2 core without
# touching the per-role enables in tfvars.
#
# Exclusivity: one workspace = one live cluster manager on the shared
# SmartStore bucket. The postcondition on the EKS listing below fails any
# ec2-mode plan while a splunk-sok-<env> EKS cluster exists; the sok layer
# carries the mirror guard against running EC2 core instances.
###############################################################################

locals {
  core_on = var.deployment_model == "ec2" ? 1 : 0

  enable_splunk_manager            = var.enable_splunk_manager * local.core_on
  enable_splunk_deployer           = var.enable_splunk_deployer * local.core_on
  enable_splunk_license            = var.enable_splunk_license * local.core_on
  enable_splunk_monitoring_console = var.enable_splunk_monitoring_console * local.core_on
  enable_splunk_indexer            = var.enable_splunk_indexer * local.core_on
  enable_splunk_searchhead         = var.enable_splunk_searchhead * local.core_on

  # The HF edge tier survives model=sok in hybrid mode.
  enable_splunk_forwarder = var.deployment_model == "ec2" ? var.enable_splunk_forwarder : (var.sok_edge_on_ec2 ? var.enable_splunk_forwarder : 0)
}

# Postcondition (not a resource) so ec2-mode plans stay diff-identical: fails
# the plan/apply if this workspace's SOK EKS cluster exists while the EC2 core
# is enabled.
data "aws_eks_clusters" "sok_exclusivity" {
  lifecycle {
    postcondition {
      condition     = local.core_on == 0 || !contains(self.names, "splunk-sok-${var.environment}")
      error_message = "EKS cluster splunk-sok-${var.environment} exists: the SOK deployment model is live for this workspace. Refusing to start the EC2 Splunk core against the same SmartStore bucket. Destroy the eks/sok layers first, or set deployment_model = \"sok\"."
    }
  }
}
