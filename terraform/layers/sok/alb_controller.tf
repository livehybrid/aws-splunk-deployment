###############################################################################
# AWS Load Balancer Controller — IRSA role + Helm release.
#
# Moved here from the eks layer: the helm provider requires a live cluster at
# apply time, which the eks layer can't guarantee on a fresh deploy (the cluster
# is created in the same apply). The sok layer reads the cluster endpoint from
# data.aws_eks_cluster.this (concrete at plan time), so the provider init never
# races the cluster creation.
###############################################################################

data "aws_iam_policy_document" "alb_controller_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "splunk-sok-${var.environment}-alb-controller"
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

  # On a cold cluster the controller pod waits on scheduling + an ECR
  # pull-through-cache miss, which can outrun helm's 5-minute default.
  timeout = 600

  # A failed install otherwise leaves a `failed` release behind that terraform
  # never records in state, so the NEXT apply dies with "cannot re-use a name
  # that is still in use" and needs a manual `helm delete`. atomic rolls the
  # failure back so `terraform apply` is simply retryable, which matters most
  # here, since a half-installed release means the webhooks below exist with no
  # backing pods (see the enableServiceMutatorWebhook note).
  atomic          = true
  cleanup_on_fail = true

  set = [
    {
      name  = "clusterName"
      value = data.aws_eks_cluster.this.name
    },
    {
      name  = "region"
      value = var.region
    },
    {
      name  = "vpcId"
      value = data.aws_eks_cluster.this.vpc_config[0].vpc_id
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.alb_controller.arn
    },
    # Pull via the account layer's ECR pull-through cache instead of directly
    # from public.ecr.aws (no VPC endpoint / PrivateLink for ECR Public exists).
    {
      name  = "image.repository"
      value = "${local.ecr_registry}/ecr-public/eks/aws-load-balancer-controller"
    },
    {
      name  = "image.tag"
      value = "v2.13.0"
    },
    # ⚠ Turn OFF the service mutator webhook (chart default: ON, failurePolicy
    # Fail, no namespace selector, objectSelector excluding only the
    # controller's OWN service). With it on, EVERY Service create anywhere in
    # the cluster is routed through the controller's webhook endpoint, so while
    # this release is still coming up the API server rejects them with:
    #   Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
    #   ... no endpoints available for service "aws-load-balancer-webhook-service"
    # That is what failed the splunk-operator helm install on a fresh apply (the
    # operator chart ships a controller-manager Service), and it makes an
    # unhealthy ALB controller a cluster-wide outage for Service creation.
    # The webhook exists ONLY to default `spec.loadBalancerClass` on new
    # type=LoadBalancer Services so the controller adopts them as NLBs; this
    # estate exposes everything through Ingress/ALB and creates no
    # type=LoadBalancer Service at all, so the webhook buys nothing. Set this
    # back to true (and keep the operator ordering below) if that ever changes.
    {
      name  = "enableServiceMutatorWebhook"
      value = "false"
    }
  ]
}