###############################################################################
# Splunk AI tier: object storage for model weights and AI artifacts.
#
# Lives here, in the persistent layer, for the same reason SmartStore does: the
# weights are staged once (>120 GB from Hugging Face, see
# scripts/ai-stage-models.sh) and must survive the nightly destroy and rebuild
# of the eks/sok/ai layers.
#
# Encryption is SSE-S3, not the SmartStore KMS key, and the bucket policy does
# NOT carry the DenyUnencrypted statement: neither Ray nor the upstream model
# upload scripts send the x-amz-server-side-encryption header, so that
# statement would reject every write. Default bucket encryption still encrypts
# every object.
#
# No prevent_destroy. Turning ai_tier_enabled off with weights staged fails at
# apply instead, because S3 will not delete a non-empty bucket (force_destroy
# stays false). Empty it deliberately first.
###############################################################################

locals {
  ai_bucket_name = "${local.account_name}-splunk-ai-${local.environment}"
}

module "s3_policy_ai" {
  count = var.ai_tier_enabled ? 1 : 0

  source           = "../../modules/s3_bucket_policy"
  bucket_name      = local.ai_bucket_name
  encrypted_bucket = false
}

resource "aws_s3_bucket" "ai" {
  count = var.ai_tier_enabled ? 1 : 0

  bucket = local.ai_bucket_name

  tags = {
    Name = local.ai_bucket_name
  }
}

resource "aws_s3_bucket_public_access_block" "ai" {
  count = var.ai_tier_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.ai[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ai" {
  count = var.ai_tier_enabled ? 1 : 0

  bucket = aws_s3_bucket.ai[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ai" {
  count = var.ai_tier_enabled ? 1 : 0

  bucket = aws_s3_bucket.ai[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "ai" {
  count = var.ai_tier_enabled ? 1 : 0

  bucket = aws_s3_bucket.ai[0].id
  policy = module.s3_policy_ai[0].json

  depends_on = [aws_s3_bucket_public_access_block.ai]
}

output "ai_bucket_name" {
  description = "Artifacts bucket for the Splunk AI tier (model weights). Empty when ai_tier_enabled is false."
  value       = var.ai_tier_enabled ? aws_s3_bucket.ai[0].bucket : ""
}
