locals {
  disallowed_encryption = var.encryption_type == "AES256" ? "aws:kms" : "AES256"
  policy_vars = {
    bucket_name           = var.bucket_name
    encryption_type       = var.encryption_type
    disallowed_encryption = local.disallowed_encryption
    required_kms_arn      = var.required_kms_arn
  }

  policy = <<-POLICY
{
                  "Version": "2012-10-17",
                  "Statement": [
                  ${join(",", compact(tolist([
  var.encrypted_bucket ? templatefile("${path.module}/segments/encrypted_bucket.tpl", { bucket_name = var.bucket_name, encryption_type = var.encryption_type, disallowed_encryption = local.disallowed_encryption, required_kms_arn = var.required_kms_arn }) : "",
  var.prevent_public_access ? templatefile("${path.module}/segments/prevent_public_access.tpl", { bucket_name = var.bucket_name, encryption_type = var.encryption_type, disallowed_encryption = local.disallowed_encryption, required_kms_arn = var.required_kms_arn }) : "",
  var.required_kms_arn != "" ? templatefile("${path.module}/segments/required_kms_usage.tpl", { bucket_name = var.bucket_name, encryption_type = var.encryption_type, disallowed_encryption = local.disallowed_encryption, required_kms_arn = var.required_kms_arn }) : "",
  var.ssl_access ? templatefile("${path.module}/segments/ssl_access.tpl", { bucket_name = var.bucket_name, encryption_type = var.encryption_type, disallowed_encryption = local.disallowed_encryption, required_kms_arn = var.required_kms_arn }) : ""
])))}
                  ]
              }
            POLICY
}
