data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "this" {
  name = "splunk-sok-${local.environment}"
}

locals {
  enabled     = var.ai_tier_enabled
  environment = lower(var.environment)
  namespace   = var.sok_namespace

  oidc_provider     = trimprefix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider}"

  # Same naming root as the account layer that creates the bucket
  # (account/locals.tf, account/ai.tf).
  ai_bucket_name      = "${var.bucket_prefix}-splunk-${local.environment}-splunk-ai-${local.environment}"
  ai_artifacts_prefix = "artifacts"

  # Images through the account layer's ECR pull-through cache when it is on,
  # exactly as the sok layer does for Splunk.
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image        = { for k, ref in var.ai_images : k => var.use_ecr_pullthrough_cache ? "${local.ecr_registry}/docker-public/${trimprefix(ref, "docker.io/")}" : ref }

  # The SOK standalone search head the AI tier trusts and serves. Mirrors how
  # the sok layer resolves its search heads: with both search-head maps empty
  # the legacy enable_shc switch decides, and a standalone named "default"
  # exists only when enable_shc is false.
  legacy_shape  = length(var.sok_standalone_search_heads) == 0 && length(var.sok_search_head_clusters) == 0
  standalone_sh = local.legacy_shape ? (var.enable_shc ? [] : ["default"]) : keys(var.sok_standalone_search_heads)
  sh_cr         = "sh-${var.ai_search_head}"
  sh_service    = "splunk-${local.sh_cr}-standalone-service"
  splunk_secret = "splunk-${local.namespace}-secret"

  # The tested issuer contract: a short, namespace-local service URL, identical
  # in the token's `iss` claim, the Splunk issuer_uri and the AIPlatform
  # endpoint. That is why the AIPlatform lives in the SOK namespace rather than
  # its own: the short name only resolves from the same namespace.
  splunk_issuer = "https://${local.sh_service}:8089"

  gpu_groups = { for k, ng in var.eks_node_groups : k => ng if ng.gpu }

  # Service accounts the AIPlatform components run as; all assume one IRSA role
  # scoped to the artifacts bucket.
  service_accounts = {
    platform = "ai-platform"
    saia     = "ai-saia"
    slim     = "ai-slim"
    ray      = "ai-ray-worker"
  }
}
