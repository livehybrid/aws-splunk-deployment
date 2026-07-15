###############################################################################
# IRSA for SmartStore: no static S3 keys anywhere. The CM and indexer pods
# run under ServiceAccount splunk-idx, whose IAM role mirrors the EC2 indexer
# role's SmartStore statements, scoped to this workspace's bucket + KMS key.
#
# The smartstore volume in the ClusterManager CR carries NO secretRef,
# splunkd reads AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN (webhook-injected)
# and uses STS AssumeRoleWithWebIdentity. AWS_STS_REGIONAL_ENDPOINTS=regional
# is injected by the EKS pod identity webhook by default; the K3 gate asserts
# it. EKS Pod Identity (the newer mechanism) is NOT confirmed to work with
# splunkd, stay on IRSA.
#
# Roles are recreated with the cluster's OIDC provider on every nightly
# destroy/recreate cycle, trust policies are derived, never hand-pasted.
###############################################################################

data "aws_iam_policy_document" "smartstore_trust" {
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
      values   = ["system:serviceaccount:${local.namespace}:splunk-idx"]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.terraform_remote_state.eks.outputs.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "smartstore" {
  statement {
    sid       = "SmartStoreList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [data.aws_s3_bucket.smartstore.arn]
  }

  statement {
    sid = "SmartStoreObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${data.aws_s3_bucket.smartstore.arn}/*"]
  }

  statement {
    sid = "SmartStoreKms"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [data.aws_kms_alias.smartstore.target_key_arn]
  }
}

resource "aws_iam_role" "smartstore" {
  name               = "splunk-sok-${var.environment}-smartstore"
  assume_role_policy = data.aws_iam_policy_document.smartstore_trust.json
}

resource "aws_iam_role_policy" "smartstore" {
  name   = "smartstore"
  role   = aws_iam_role.smartstore.id
  policy = data.aws_iam_policy_document.smartstore.json
}

resource "kubernetes_service_account_v1" "splunk_idx" {
  metadata {
    name      = "splunk-idx"
    namespace = local.namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.smartstore.arn
    }
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}
