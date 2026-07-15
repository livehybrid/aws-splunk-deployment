###############################################################################
# S3 buckets for the LiveHybrid Splunk C3 deployment.
#
# - resources: shared apps/config artefacts (PKI CA download target etc).
# - ma-certs:  PKI certificates issued to instances.
# - checkpoints: Heavy Forwarder bucket-based checkpointing.
# - splunk_smartstore: SmartStore warm/cold tier (per-workspace bucket).
# - terraform-state bucket is created out-of-band; its bucket policy is set
#   here once the bucket exists.
###############################################################################

module "s3_policy_resources" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = "${local.account_name}-resources"
  encrypted_bucket = true
}

resource "aws_s3_bucket" "resources" {
  bucket = "${local.account_name}-resources"

  tags = {
    project     = "splunk"
    Name        = "${local.account_name}-resources"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "resources" {
  bucket                  = aws_s3_bucket.resources.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "resources" {
  bucket = aws_s3_bucket.resources.id
  policy = module.s3_policy_resources.json
}

resource "aws_s3_bucket_server_side_encryption_configuration" "resources" {
  bucket = aws_s3_bucket.resources.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "resources" {
  bucket = aws_s3_bucket.resources.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  rule {
    id     = "tier-after-30d"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

module "s3_policy_ma-certs" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = "${local.account_name}-ma-certs"
  encrypted_bucket = true
  required_kms_arn = aws_kms_key.pki.arn
  encryption_type  = "aws:kms"
}

resource "aws_s3_bucket" "ma-certs" {
  bucket = "${local.account_name}-ma-certs"

  tags = {
    project     = "splunk"
    Name        = "${local.account_name}-ma-certs"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "ma-certs" {
  bucket                  = aws_s3_bucket.ma-certs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "ma-certs" {
  bucket = aws_s3_bucket.ma-certs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ma-certs" {
  bucket = aws_s3_bucket.ma-certs.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.pki.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_policy" "ma-certs" {
  bucket = aws_s3_bucket.ma-certs.id
  policy = module.s3_policy_ma-certs.json
}

resource "aws_s3_bucket_lifecycle_configuration" "ma-certs" {
  bucket = aws_s3_bucket.ma-certs.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  # Versioning protects against accidental overwrite/delete of cert material;
  # superseded versions have no value after 90 days.
  rule {
    id     = "expire-noncurrent-90d"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

module "s3_policy_terraform" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = "${local.account_name}-terraform"
  encrypted_bucket = true
  encryption_type  = "AES256"
}

resource "aws_s3_bucket_policy" "s3_terraform_policy" {
  bucket = "${local.account_name}-terraform"
  policy = module.s3_policy_terraform.json
}

resource "aws_s3_account_public_access_block" "block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "s3_policy_splunk_checkpoints" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = "${local.account_name}-splunk-checkpoints"
  encrypted_bucket = true
  required_kms_arn = aws_kms_key.checkpoints.arn
  encryption_type  = "aws:kms"
}

resource "aws_s3_bucket" "checkpoints" {
  bucket = "${local.account_name}-splunk-checkpoints"

  tags = {
    project     = "splunk"
    Name        = "${local.account_name}-splunk-checkpoints"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "checkpoints" {
  bucket                  = aws_s3_bucket.checkpoints.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.checkpoints.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_policy" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id
  policy = module.s3_policy_splunk_checkpoints.json
}

resource "aws_s3_bucket_lifecycle_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  # Checkpoints are rolling state — only the current version matters.
  rule {
    id     = "expire-noncurrent-30d"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

###############################################################################
# SmartStore — per-workspace bucket and KMS key for warm/cold indexer tier.
###############################################################################

module "s3_policy_splunk_smartstore" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = "${local.account_name}-splunk-smartstore-${var.environment}"
  encrypted_bucket = true
  required_kms_arn = element(concat(aws_kms_key.splunk-smartstore.*.arn, tolist([""])), 0)
  encryption_type  = "aws:kms"
}

resource "aws_s3_bucket" "splunk_smartstore" {
  count  = var.enable_smartstore
  bucket = "${local.account_name}-splunk-smartstore-${var.environment}"

  tags = {
    project     = "splunk"
    Name        = "${local.account_name}-splunk-smartstore-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "splunk_smartstore" {
  count                   = var.enable_smartstore
  bucket                  = aws_s3_bucket.splunk_smartstore[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "splunk_smartstore" {
  count  = var.enable_smartstore
  bucket = aws_s3_bucket.splunk_smartstore[0].id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.splunk-smartstore[0].arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_policy" "splunk_smartstore" {
  count  = var.enable_smartstore
  bucket = aws_s3_bucket.splunk_smartstore[0].id
  policy = module.s3_policy_splunk_smartstore.json
}

# Tiered lifecycle: keep recent on Standard, move to INTELLIGENT_TIERING after
# 30 days so cold buckets land in cheaper tiers without operator action.
resource "aws_s3_bucket_lifecycle_configuration" "splunk_smartstore" {
  count  = var.enable_smartstore
  bucket = aws_s3_bucket.splunk_smartstore[0].id

  rule {
    id     = "tier-after-30d"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # SmartStore uploads are multipart; interrupted ones (instance recycle, spot
  # reclaim) otherwise linger invisibly and bill forever.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}
