###############################################################################
# SmartStore bucket + KMS key — the warm/cold tier for the SOK indexers.
#
# Faithfully mirrors the account layer's SmartStore resources (bucket naming,
# SSE-KMS, private ACLs, tiered lifecycle, KMS rotation) so the same discovery
# conventions and the same IRSA/KMS grants work identically to prod:
#   bucket: livehybrid-splunk-<env>-splunk-smartstore-<env>
#   alias:  alias/splunk-smartstore-<env>-key
# The sok layer's IRSA role (irsa.tf) grants S3 + kms:Decrypt/GenerateDataKey on
# exactly these ARNs; the ClusterManager CR points its remote volume here.
###############################################################################

data "aws_caller_identity" "current" {}

# When this layer does NOT create the key (prod), the apps/kvbackup buckets
# still encrypt with the workspace SmartStore key — discover the account-layer
# one by its alias.
data "aws_kms_alias" "smartstore_existing" {
  count = var.sok_foundation_create_smartstore ? 0 : 1
  name  = "alias/splunk-smartstore-${var.environment}-key"
}

locals {
  account_name = "livehybrid-splunk-${var.environment}"
  bucket_name  = "${local.account_name}-splunk-smartstore-${var.environment}"

  smartstore_kms_arn = var.sok_foundation_create_smartstore ? aws_kms_key.smartstore[0].arn : data.aws_kms_alias.smartstore_existing[0].target_key_arn
}

resource "aws_kms_key" "smartstore" {
  count                   = var.sok_foundation_create_smartstore ? 1 : 0
  deletion_window_in_days = 7
  description             = "Splunk SmartStore (${var.environment}) bucket encryption key"
  enable_key_rotation     = true

  tags = {
    Name        = "splunk-smartstore-${var.environment}-key"
    source      = "terraform"
    project     = "splunk"
    Environment = var.environment
  }

  # Holds the key that encrypts indexed data surviving every nightly teardown —
  # never let a destroy take it.
  lifecycle {
    prevent_destroy = true
  }

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": { "AWS": ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"] },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_kms_alias" "smartstore" {
  count         = var.sok_foundation_create_smartstore ? 1 : 0
  name          = "alias/splunk-smartstore-${var.environment}-key"
  target_key_id = aws_kms_key.smartstore[0].id
}

module "s3_policy_smartstore" {
  count            = var.sok_foundation_create_smartstore ? 1 : 0
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = local.bucket_name
  encrypted_bucket = true
  required_kms_arn = local.smartstore_kms_arn
  encryption_type  = "aws:kms"
}

resource "aws_s3_bucket" "smartstore" {
  count  = var.sok_foundation_create_smartstore ? 1 : 0
  bucket = local.bucket_name

  tags = {
    project     = "splunk"
    Name        = local.bucket_name
    Environment = var.environment
  }

  # Source of truth for every byte of indexed data — never let a terraform
  # destroy take it (the KMS key already carries this guard; the bucket needs it
  # too). The foundation layer is persistent and out of the nightly teardown.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning: recover from an accidental delete/overwrite. SmartStore writes
# immutable bucket files, so churn is low; noncurrent versions expire after 30d
# (lifecycle below) to bound cost.
resource "aws_s3_bucket_versioning" "smartstore" {
  count  = var.sok_foundation_create_smartstore ? 1 : 0
  bucket = aws_s3_bucket.smartstore[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "smartstore" {
  count                   = var.sok_foundation_create_smartstore ? 1 : 0
  bucket                  = aws_s3_bucket.smartstore[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "smartstore" {
  count  = var.sok_foundation_create_smartstore ? 1 : 0
  bucket = aws_s3_bucket.smartstore[0].id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = local.smartstore_kms_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_policy" "smartstore" {
  count  = var.sok_foundation_create_smartstore ? 1 : 0
  bucket = aws_s3_bucket.smartstore[0].id
  policy = module.s3_policy_smartstore[0].json
}

# Tiered lifecycle: recent buckets on Standard, INTELLIGENT_TIERING after 30d so
# cold buckets land in cheaper tiers without operator action. Interrupted
# multipart uploads (SmartStore uploads are multipart) are aborted after 3 days
# so they don't linger invisibly and bill forever.
resource "aws_s3_bucket_lifecycle_configuration" "smartstore" {
  count  = var.sok_foundation_create_smartstore ? 1 : 0
  bucket = aws_s3_bucket.smartstore[0].id

  rule {
    id     = "tier-after-30d"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }

  # Bound the cost of versioning: drop noncurrent versions after 30 days (an
  # accidental delete is still recoverable for a month).
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
