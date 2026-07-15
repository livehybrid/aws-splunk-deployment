###############################################################################
# sok_foundation_create_smartstore introduced count on the SmartStore
# resources (dev owns them; prod's are account-layer-owned and must not be
# re-created). These moved blocks keep the EXISTING dev state addresses intact
# — without them the plan would read as destroy(prevent_destroy!)+create.
###############################################################################

moved {
  from = aws_kms_key.smartstore
  to   = aws_kms_key.smartstore[0]
}

moved {
  from = aws_kms_alias.smartstore
  to   = aws_kms_alias.smartstore[0]
}

moved {
  from = module.s3_policy_smartstore
  to   = module.s3_policy_smartstore[0]
}

moved {
  from = aws_s3_bucket.smartstore
  to   = aws_s3_bucket.smartstore[0]
}

moved {
  from = aws_s3_bucket_versioning.smartstore
  to   = aws_s3_bucket_versioning.smartstore[0]
}

moved {
  from = aws_s3_bucket_public_access_block.smartstore
  to   = aws_s3_bucket_public_access_block.smartstore[0]
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.smartstore
  to   = aws_s3_bucket_server_side_encryption_configuration.smartstore[0]
}

moved {
  from = aws_s3_bucket_policy.smartstore
  to   = aws_s3_bucket_policy.smartstore[0]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.smartstore
  to   = aws_s3_bucket_lifecycle_configuration.smartstore[0]
}
