resource "aws_iam_role_policy" "splunk_idx" {
  name   = "SplunkIndexer"
  role   = aws_iam_role.splunk_idx.id
  policy = data.aws_iam_policy_document.splunk.json
}

resource "aws_iam_instance_profile" "splunk_idx" {
  name = aws_iam_role.splunk_idx.name
  role = aws_iam_role.splunk_idx.name
}
#Used to send SNS alerts from Splunk
resource "aws_iam_role_policy" "sns-security-alert_idx" {
  name   = "sns-security-alert"
  role   = aws_iam_role.splunk_idx.id
  policy = data.aws_iam_policy_document.sns-security-alert.json
}

resource "aws_iam_role" "splunk_idx" {
  name                  = "SplunkIndexer"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy" "s3_ca_crt_access_idx" {
  name   = "s3_ca_crt_access"
  role   = aws_iam_role.splunk_idx.id
  policy = data.aws_iam_policy_document.s3_ca_crt_access.json
}

data "aws_iam_policy_document" "volume_mount_idx" {

  statement {
    actions = [
      "ec2:DescribeVolumes"
    ]
    resources = [
      "*"
    ]
  }

  statement {
    actions = [
      "ec2:AttachVolume"
    ]
    resources = [
      "*"
    ]
  }
}

resource "aws_iam_role_policy" "volume_mount_idx" {
  name   = "volume_mount"
  role   = aws_iam_role.splunk_idx.id
  policy = data.aws_iam_policy_document.volume_mount_idx.json
}

resource "aws_iam_role_policy" "ssm_access_idx" {
  name   = "ssm_access"
  role   = aws_iam_role.splunk_idx.id
  policy = data.aws_iam_policy_document.ssm_policy.json
}

resource "aws_iam_role_policy" "private_route53_idx" {
  name   = "private_route53"
  role   = aws_iam_role.splunk_idx.id
  policy = data.aws_iam_policy_document.private_route53.json
}

resource "aws_iam_role_policy" "ec2_indexer_secretfile" {
  count = var.enable_splunk_indexer

  name   = "secrets-file"
  policy = data.aws_iam_policy_document.splunk_secret_file.json
  role   = aws_iam_role.splunk_idx.id
}

###############################################################################
# SmartStore access — indexers read/write warm/cold buckets to S3 and use the
# per-workspace KMS key to encrypt them.
###############################################################################

data "aws_iam_policy_document" "smartstore_idx" {
  count = var.enable_smartstore

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${lookup(local.s3["splunk-smartstore"], "arn")}/*"]
  }

  statement {
    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [lookup(local.s3["splunk-smartstore"], "arn")]
  }

  statement {
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [lookup(local.kms["splunk-smartstore"], "arn")]
  }
}

resource "aws_iam_role_policy" "smartstore_idx" {
  count  = var.enable_smartstore
  name   = "smartstore"
  role   = aws_iam_role.splunk_idx.id
  policy = data.aws_iam_policy_document.smartstore_idx[0].json
}
