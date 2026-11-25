locals {
  public_acls   = ["public-read", "public-read-write", "authenticated-read"]
  public_grants = ["*http://acs.amazonaws.com/groups/global/AllUsers*", "*http://acs.amazonaws.com/groups/global/AuthenticatedUsers*"]

  public_acl_denies = {
    DenyPublicReadACL   = { actions = ["s3:PutObject", "s3:PutObjectAcl"], resource = "arn:aws:s3:::${var.bucket_name}/*", test = "StringEquals", variable = "s3:x-amz-acl", values = local.public_acls }
    DenyPublicReadGrant = { actions = ["s3:PutObject", "s3:PutObjectAcl"], resource = "arn:aws:s3:::${var.bucket_name}/*", test = "StringLike", variable = "s3:x-amz-grant-read", values = local.public_grants }
    DenyPublicListACL   = { actions = ["s3:PutBucketAcl"], resource = "arn:aws:s3:::${var.bucket_name}", test = "StringEquals", variable = "s3:x-amz-acl", values = local.public_acls }
    DenyPublicListGrant = { actions = ["s3:PutBucketAcl"], resource = "arn:aws:s3:::${var.bucket_name}", test = "StringLike", variable = "s3:x-amz-grant-read", values = local.public_grants }
  }
}

data "aws_iam_policy_document" "this" {
  dynamic "statement" {
    for_each = var.ssl_access ? [1] : []
    content {
      sid     = "DenyNonSSL"
      effect  = "Deny"
      actions = ["s3:*"]
      resources = [
        "arn:aws:s3:::${var.bucket_name}",
        "arn:aws:s3:::${var.bucket_name}/*",
      ]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "Bool"
        variable = "aws:SecureTransport"
        values   = ["false"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.encrypted_bucket && var.required_kms_arn != "" ? [1] : []
    content {
      sid     = "DenyWrongKMS"
      effect  = "Deny"
      actions = ["s3:PutObject"]
      resources = [
        "arn:aws:s3:::${var.bucket_name}/*",
      ]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "StringNotEquals"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = [var.required_kms_arn]
      }
    }
  }

  dynamic "statement" {
    for_each = var.encrypted_bucket ? [1] : []
    content {
      sid     = "DenyUnencrypted"
      effect  = "Deny"
      actions = ["s3:PutObject"]
      resources = [
        "arn:aws:s3:::${var.bucket_name}/*",
      ]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "StringNotEquals"
        variable = "s3:x-amz-server-side-encryption"
        values   = [var.encryption_type]
      }
    }
  }

  # Deny making objects or the bucket readable by everyone, or by every AWS
  # account, through an ACL: both as a canned ACL and as an explicit grant.
  # Belt and braces with S3 Block Public Access and BucketOwnerEnforced
  # ownership, either of which a later change could relax.
  dynamic "statement" {
    for_each = var.prevent_public_access ? local.public_acl_denies : {}
    content {
      sid       = statement.key
      effect    = "Deny"
      actions   = statement.value.actions
      resources = [statement.value.resource]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = statement.value.test
        variable = statement.value.variable
        values   = statement.value.values
      }
    }
  }
}
