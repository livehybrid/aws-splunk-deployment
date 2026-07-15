###############################################################################
# Apps bucket, App Framework source for the SOK tiers (git -> S3 -> operator).
#
# Persistent, like the SmartStore bucket: the operator's App-Framework Download
# phase reads it (only the operator pod does, Splunk pods receive apps via
# PodCopy), so it must survive the nightly eks/sok destroy/recreate. Private,
# SSE-KMS with the same workspace KMS key as SmartStore.
#
# Layout (per-scope prefixes, written by scripts/package-apps.sh):
#   idx-apps/   -> ClusterManager CR, scope cluster (cluster bundle -> indexers)
#   sh-apps/    -> Standalone CR, scope local
#   shc-apps/   -> SearchHeadCluster CR, scope local  (prod)
#   cm-apps/    -> ClusterManager CR, scope local     (CM's own apps)
###############################################################################

locals {
  apps_bucket_name = "${local.account_name}-splunk-apps-${var.environment}"
}

module "s3_policy_apps" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = local.apps_bucket_name
  encrypted_bucket = true
  required_kms_arn = local.smartstore_kms_arn
  encryption_type  = "aws:kms"
}

resource "aws_s3_bucket" "apps" {
  bucket = local.apps_bucket_name

  tags = {
    project     = "splunk"
    Name        = local.apps_bucket_name
    Environment = var.environment
  }

  # The App-Framework source of truth for every SOK tier, never let a destroy
  # take it (mirrors smartstore/kvbackup). The foundation layer is persistent and
  # out of the nightly teardown.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning: recover from an accidental delete/overwrite of an app package.
# Noncurrent versions expire after 30d (lifecycle below) to bound cost, matching
# the smartstore/kvbackup convention.
resource "aws_s3_bucket_versioning" "apps" {
  bucket = aws_s3_bucket.apps.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "apps" {
  bucket                  = aws_s3_bucket.apps.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "apps" {
  bucket = aws_s3_bucket.apps.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = local.smartstore_kms_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_policy" "apps" {
  bucket = aws_s3_bucket.apps.id
  policy = module.s3_policy_apps.json
}

# Abort interrupted multipart uploads (package-apps.sh uploads can be large).
resource "aws_s3_bucket_lifecycle_configuration" "apps" {
  bucket = aws_s3_bucket.apps.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }

  # Bound the cost of versioning: drop noncurrent versions after 30 days (an
  # accidental delete/overwrite is still recoverable for a month).
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
