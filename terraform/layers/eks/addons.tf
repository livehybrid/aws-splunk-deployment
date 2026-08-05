###############################################################################
# AWS Load Balancer Controller, provisions the S2S/HEC NLBs (Service type
# LoadBalancer, ip targets) and any future ALB Ingress. IAM policy is the
# vendored upstream document (files/alb-controller-iam-policy.json, from
# aws-load-balancer-controller v2.13.0).
#
# external-dns is deliberately NOT installed yet: the dev public zone
# (splunk.dev.livehybrid.com) is not delegated at the registrar, so there is
# nothing it could publish that would resolve. Add it (domain-filtered) once
# delegation exists, see docs/kubernetes-sok-plan.md K3.6.
###############################################################################

###############################################################################
# ECR pull-through cache (mirrors public.ecr.aws, see account layer ecr.tf).
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

resource "aws_iam_policy" "ecr_pull_through_cache" {
  name = "${local.cluster_name}-ecr-pull-through-cache"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "EcrPullThroughCache"
      Effect   = "Allow"
      Action   = ["ecr:BatchImportUpstreamImage", "ecr:CreateRepository"]
      Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/ecr-public/*"
    }]
  })
}

data "aws_iam_policy_document" "alb_controller_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${local.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_trust.json
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "alb-controller"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/files/alb-controller-iam-policy.json")
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.13.0"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = data.aws_vpc.this.id
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  # Pull via the account layer's ECR pull-through cache instead of directly
  # from public.ecr.aws (no VPC endpoint / PrivateLink for ECR Public exists),
  # so this keeps working even on nodes with no internet egress. Chart default
  # otherwise resolves to public.ecr.aws/eks/aws-load-balancer-controller.
  set {
    name  = "image.repository"
    value = "${local.ecr_registry}/ecr-public/eks/aws-load-balancer-controller"
  }
  set {
    name  = "image.tag"
    value = "v2.13.0"
  }

  # module.eks attaches the ecr_pull_through_cache policy to the node role
  # (iam_role_additional_policies, eks.tf) before any pod on it can pull.
  depends_on = [module.eks]
}
