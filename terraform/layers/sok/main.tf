###############################################################################
# Locals + AWS foundation discovery (naming conventions, not remote state,
# see the eks layer header).
###############################################################################

locals {
  # The sok layer owns the namespace (created in operator.tf); the operator and
  # every Splunk CR must share it (namespace-scoped WATCH_NAMESPACE).
  namespace = var.sok_namespace

  # Same naming root as the account layer that CREATES these buckets
  # (account/locals.tf). They previously disagreed, so this layer could not
  # find the buckets on a fresh account.
  bucket_root            = "${var.bucket_prefix}-splunk-${local.environment}"
  smartstore_bucket_name = var.smartstore_bucket_name_override != "" ? var.smartstore_bucket_name_override : "${local.bucket_root}-splunk-smartstore-${local.environment}"

  # data_volume_filesystem (shared knob, xfs|ext4) picks the StorageClass the
  # CR volume configs reference.
  storage_class = "splunk-gp3-${var.data_volume_filesystem}"

  # The operator's REST client and bundle-push exec authenticate as the
  # literal user `admin`, inside SOK the admin account is `admin`, NOT the
  # estate's `splunkadmin` (deliberate, documented divergence).
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # Images either go through the account's ECR pull-through cache (the estate's
  # posture, for nodes with no internet path) or straight to their upstream
  # registries. The rewrite is per-prefix because account/ecr.tf maps one cache
  # prefix per upstream: docker-public -> registry-1.docker.io, k8s-public ->
  # registry.k8s.io, ecr-public -> public.ecr.aws.
  ecr_cache = var.use_ecr_pullthrough_cache

  # Where the control planes send their OWN telemetry. See
  # var.sok_internal_hec_url: the external ALB is unreachable from inside the
  # cluster whenever its allow-list does not carry the cluster's egress, and
  # the emit is synchronous.
  internal_hec_url = (
    var.sok_internal_hec_url != "" ? var.sok_internal_hec_url : "https://${local.hec_host}/"
  )
}

# Discovered by naming convention (matching the account layer and prod). These
# are created by the persistent account layer, apply that first.
data "aws_s3_bucket" "smartstore" {
  bucket = local.smartstore_bucket_name
}

data "aws_kms_alias" "smartstore" {
  name = "alias/splunk-smartstore-${local.environment}-key"
}

