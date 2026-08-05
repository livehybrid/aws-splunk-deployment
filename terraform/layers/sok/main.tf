###############################################################################
# Locals + AWS foundation discovery (naming conventions, not remote state,
# see the eks layer header).
###############################################################################

locals {
  # The sok layer owns the namespace (created in operator.tf); the operator and
  # every Splunk CR must share it (namespace-scoped WATCH_NAMESPACE).
  namespace = var.sok_namespace

  smartstore_bucket_name = "${var.bucket_prefix}-${var.environment}-splunk-smartstore"

  # data_volume_filesystem (shared knob, xfs|ext4) picks the StorageClass the
  # CR volume configs reference.
  storage_class = "splunk-gp3-${var.data_volume_filesystem}"

  # The operator's REST client and bundle-push exec authenticate as the
  # literal user `admin`, inside SOK the admin account is `admin`, NOT the
  # estate's `splunkadmin` (deliberate, documented divergence).
  splunk_image = var.sok_splunk_image
}

# Discovered by naming convention (matching the foundation layer). These are
# created by the persistent foundation layer, apply that first.
data "aws_s3_bucket" "smartstore" {
  bucket = local.smartstore_bucket_name
}

data "aws_kms_alias" "smartstore" {
  name = "alias/splunk-smartstore-${var.environment}-key"
}

