###############################################################################
# Locals + AWS foundation discovery (naming conventions, not remote state —
# see the eks layer header) + the EC2/SOK exclusivity guard.
###############################################################################

locals {
  # The sok layer owns the namespace (created in operator.tf); the operator and
  # every Splunk CR must share it (namespace-scoped WATCH_NAMESPACE).
  namespace = var.sok_namespace

  smartstore_bucket_name = "livehybrid-splunk-${var.environment}-splunk-smartstore-${var.environment}"

  # data_volume_filesystem (shared knob, xfs|ext4) picks the StorageClass the
  # CR volume configs reference.
  storage_class = "splunk-gp3-${var.data_volume_filesystem}"

  # The operator's REST client and bundle-push exec authenticate as the
  # literal user `admin` — inside SOK the admin account is `admin`, NOT the
  # estate's `splunkadmin` (deliberate, documented divergence).
  splunk_image = var.sok_splunk_image
}

# Discovered by naming convention (matching the account layer and prod). These
# are created by the persistent sok-foundation layer — apply that first.
data "aws_s3_bucket" "smartstore" {
  bucket = local.smartstore_bucket_name
}

data "aws_kms_alias" "smartstore" {
  name = "alias/splunk-smartstore-${var.environment}-key"
}

# Mirror of the cluster layer's guard: refuse to build the SOK Splunk core
# while EC2 core instances (indexers / cluster manager) are running for this
# workspace — one SmartStore bucket, one live cluster manager, ever.
data "aws_instances" "ec2_core" {
  filter {
    name = "tag:Name"
    values = [
      "${var.environment}-indexer*", "${var.environment}_indexer*",
      "${var.environment}-manager*", "${var.environment}_manager*",
    ]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "pending"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 0
      error_message = "Running EC2 Splunk core instances exist for workspace ${var.environment} (${join(", ", self.ids)}). Refusing to start the SOK Splunk core against the same SmartStore bucket. Stop the cluster layer first (deployment_model exclusivity)."
    }
  }
}
