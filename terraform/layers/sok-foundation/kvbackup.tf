###############################################################################
# KV-store backup bucket — point-in-time backups of the SHC KV store.
#
# The KV store (SHC dashboard state, lookups, user content) lives on the SHC
# pods' PVCs, which the nightly-destroy model (dev) and any full teardown wipe.
# SmartStore only covers indexed data, not the KV store — so this bucket is the
# KV store's durability layer, persistent like SmartStore/apps and never part
# of the eks/sok teardown.
#
# Written by the in-cluster backup CronJob (sok layer) via IRSA; read on restore
# (start workflow / cutover). Private, SSE-KMS with the workspace key, 30-day
# retention so old backups don't accumulate.
###############################################################################

locals {
  kvbackup_bucket_name = "${local.account_name}-splunk-kvbackup-${var.environment}"
}

module "s3_policy_kvbackup" {
  source           = "../../modules/s3_bucket_policy"
  bucket_name      = local.kvbackup_bucket_name
  encrypted_bucket = true
  required_kms_arn = local.smartstore_kms_arn
  encryption_type  = "aws:kms"
}

resource "aws_s3_bucket" "kvbackup" {
  bucket = local.kvbackup_bucket_name

  tags = {
    project     = "splunk"
    Name        = local.kvbackup_bucket_name
    Environment = var.environment
  }

  # The only durability layer for the SHC KV store — never let a destroy take it.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning: a corrupt/partial backup overwrite can't clobber the last good one.
# Noncurrent versions expire with the 30-day retention (lifecycle below).
resource "aws_s3_bucket_versioning" "kvbackup" {
  bucket = aws_s3_bucket.kvbackup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "kvbackup" {
  bucket                  = aws_s3_bucket.kvbackup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kvbackup" {
  bucket = aws_s3_bucket.kvbackup.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = local.smartstore_kms_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_policy" "kvbackup" {
  bucket = aws_s3_bucket.kvbackup.id
  policy = module.s3_policy_kvbackup.json
}

resource "aws_s3_bucket_lifecycle_configuration" "kvbackup" {
  bucket = aws_s3_bucket.kvbackup.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    # With versioning on, also expire the noncurrent versions on the same clock.
    noncurrent_version_expiration {
      noncurrent_days = 30
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
}
