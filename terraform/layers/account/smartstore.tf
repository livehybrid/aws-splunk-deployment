###############################################################################
# SmartStore bucket + KMS key — the warm/cold tier for the SOK indexers.
#
#   bucket: livehybrid-splunk-<env>-splunk-smartstore-<env>
#   alias:  alias/splunk-smartstore-<env>-key
# The sok layer's IRSA role (irsa.tf) grants S3 + kms:Decrypt/GenerateDataKey on
# exactly these ARNs; the ClusterManager CR points its remote volume here.
# Persistent: this lives in the account layer, never part of the nightly
# eks/sok teardown, so indexed data survives every rebuild.
###############################################################################

locals {
  smartstore_bucket_name = "${local.account_name}-splunk-smartstore-${var.environment}"
  smartstore_kms_arn     = aws_kms_key.smartstore.arn
}

resource "aws_kms_key" "smartstore" {
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
      "Principal": { "AWS": ["arn:aws:iam::${local.account_id}:root"] },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_kms_alias" "smartstore" {
  name          = "alias/splunk-smartstore-${var.environment}-key"
  target_key_id = aws_kms_key.smartstore.id
}

module "s3_policy_smartstore" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = local.smartstore_bucket_name
  encrypted_bucket = true
  required_kms_arn = local.smartstore_kms_arn
  encryption_type  = "aws:kms"
}

resource "aws_s3_bucket" "smartstore" {
  bucket = local.smartstore_bucket_name

  tags = {
    project     = "splunk"
    Name        = local.smartstore_bucket_name
    Environment = var.environment
  }

  # Source of truth for every byte of indexed data — never let a terraform
  # destroy take it.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning: recover from an accidental delete/overwrite. SmartStore writes
# immutable bucket files, so churn is low; noncurrent versions expire after 30d
# (lifecycle below) to bound cost.
resource "aws_s3_bucket_versioning" "smartstore" {
  bucket = aws_s3_bucket.smartstore.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "smartstore" {
  bucket                  = aws_s3_bucket.smartstore.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "smartstore" {
  bucket = aws_s3_bucket.smartstore.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = local.smartstore_kms_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_policy" "smartstore" {
  bucket = aws_s3_bucket.smartstore.id
  policy = module.s3_policy_smartstore.json
}

# Tiered lifecycle: recent buckets on Standard, INTELLIGENT_TIERING after 30d so
# cold buckets land in cheaper tiers without operator action. Interrupted
# multipart uploads (SmartStore uploads are multipart) are aborted after 3 days
# so they don't linger invisibly and bill forever.
resource "aws_s3_bucket_lifecycle_configuration" "smartstore" {
  bucket = aws_s3_bucket.smartstore.id

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
