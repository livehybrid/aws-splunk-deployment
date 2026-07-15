# The sok layer discovers these by naming convention (not remote state), but
# expose them for humans and any future wiring.
# Bucket name + alias are naming convention (valid whether or not this layer
# created them); the ARNs resolve to whichever owner is live.
output "smartstore_bucket" {
  value = local.bucket_name
}

output "smartstore_bucket_arn" {
  value = "arn:aws:s3:::${local.bucket_name}"
}

output "smartstore_kms_key_arn" {
  value = local.smartstore_kms_arn
}

output "smartstore_kms_alias" {
  value = "alias/splunk-smartstore-${var.environment}-key"
}

output "apps_bucket" {
  value = aws_s3_bucket.apps.bucket
}

output "apps_bucket_arn" {
  value = aws_s3_bucket.apps.arn
}

output "kvbackup_bucket" {
  value = aws_s3_bucket.kvbackup.bucket
}

output "kvbackup_bucket_arn" {
  value = aws_s3_bucket.kvbackup.arn
}

# Persistent HEC token secret (OPS-14). The sok layer reads it by this id (naming
# convention /<env>/splunk/hec_token) via a data source; expose the id/arn for
# humans and any future wiring.
output "hec_token_secret_id" {
  value = aws_secretsmanager_secret.hec_token.id
}

output "hec_token_secret_arn" {
  value = aws_secretsmanager_secret.hec_token.arn
}
