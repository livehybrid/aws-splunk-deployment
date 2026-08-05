###############################################################################
# App Framework: git -> S3 (apps bucket) -> operator Download -> PodCopy.
#
# ONLY the operator pod reads the apps bucket (Download phase); Splunk pods
# receive apps via PodCopy, so the SmartStore IRSA (splunk-idx) does not cover
# this. The operator's own ServiceAccount (splunk-operator-controller-manager,
# created by the helm chart) gets S3 read + kms:Decrypt via this role, attached
# through splunkOperator.annotations in the helm values (operator.tf).
#
# Apps bucket lives in the persistent account layer; discovered here by
# naming convention (same as the SmartStore bucket).
###############################################################################

data "aws_s3_bucket" "apps" {
  bucket = "${var.bucket_prefix}-${var.environment}-splunk-apps"
}

data "aws_iam_policy_document" "operator_apps_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.eks.outputs.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.terraform_remote_state.eks.outputs.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.namespace}:splunk-operator-controller-manager"]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.terraform_remote_state.eks.outputs.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "operator_apps" {
  statement {
    sid       = "AppsList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [data.aws_s3_bucket.apps.arn]
  }

  statement {
    sid       = "AppsRead"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.apps.arn}/*"]
  }

  statement {
    sid       = "AppsKms"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [data.aws_kms_alias.smartstore.target_key_arn]
  }
}

resource "aws_iam_role" "operator_apps" {
  name               = "splunk-sok-${var.environment}-operator-apps"
  assume_role_policy = data.aws_iam_policy_document.operator_apps_trust.json
}

resource "aws_iam_role_policy" "operator_apps" {
  name   = "apps"
  role   = aws_iam_role.operator_apps.id
  policy = data.aws_iam_policy_document.operator_apps.json
}

locals {
  # App Framework volume (S3, IRSA, no secretRef). Reused by the CR appRepos.
  appframework_volume = {
    name        = "appvol"
    storageType = "s3"
    provider    = "aws"
    path        = data.aws_s3_bucket.apps.bucket
    endpoint    = "https://s3.${var.region}.amazonaws.com"
    region      = var.region
  }
}
