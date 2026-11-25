###############################################################################
# ECR pull-through cache (mirrors public.ecr.aws, see account layer ecr.tf).
###############################################################################

data "aws_caller_identity" "current" {}

# TODO - Righten the allow on this to specific images
resource "aws_iam_policy" "ecr_pull_through_cache" {
  name = "${local.cluster_name}-ecr-pull-through-cache"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "EcrPullThroughCache"
      Effect   = "Allow"
      Action   = ["ecr:BatchImportUpstreamImage", "ecr:CreateRepository"]
      Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*-public/*"
    }]
  })
}

