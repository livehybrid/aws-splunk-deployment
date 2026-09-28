###############################################################################
# ECR pull-through cache, mirrors public.ecr.aws into this account's private
# ECR registry on first pull (cached from then on).
#
# public.ecr.aws (ECR Public - the gallery behind images like
# public.ecr.aws/eks/aws-load-balancer-controller) has NO VPC endpoint /
# PrivateLink support; pulling it always needs real internet egress. Nodes in
# a public subnet with an IGW route (current dev/develop shape) reach it
# directly and need nothing here. Nodes with no internet path (private
# subnets, no NAT) can instead pull the cached copy through the existing
# private-ECR VPC endpoints (ecr.api/ecr.dkr, vpc_default_ep.tf) - no direct
# internet access needed for THOSE images specifically.
#
# Account-wide (one registry per account/region), so this lives here rather
# than per-environment. Callers reference images as
# "<account_id>.dkr.ecr.<region>.amazonaws.com/ecr-public/<upstream path>",
# e.g. ecr-public/eks/aws-load-balancer-controller:v2.13.0. The private repo
# for each image is created automatically on first pull (needs
# ecr:CreateRepository + ecr:BatchImportUpstreamImage on the puller's role,
# see the eks layer's node IAM policy).
###############################################################################

# Only with the cache on: the secret (Docker Hub credentials) is created by
# hand, and looking it up unconditionally breaks every account without it.
data "aws_secretsmanager_secret" "ecr_pullthroughcache_docker_hub" {
  count = var.use_ecr_pullthrough_cache ? 1 : 0

  name = "ecr-pullthroughcache/docker-hub"
}

resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  count = var.use_ecr_pullthrough_cache ? 1 : 0

  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
  # No credential_arn: ECR Public Gallery is unauthenticated for pull-through cache.
}

resource "aws_ecr_pull_through_cache_rule" "k8s_public" {
  count = var.use_ecr_pullthrough_cache ? 1 : 0

  ecr_repository_prefix = "k8s-public"
  upstream_registry_url = "registry.k8s.io"
  # No credential_arn: K8s Public Gallery is unauthenticated for pull-through cache.
}

resource "aws_ecr_pull_through_cache_rule" "docker_public" {
  count = var.use_ecr_pullthrough_cache ? 1 : 0

  ecr_repository_prefix = "docker-public"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = data.aws_secretsmanager_secret.ecr_pullthroughcache_docker_hub[0].arn
}

# State moves: the rules were unconditional before gaining a count.
moved {
  from = aws_ecr_pull_through_cache_rule.ecr_public
  to   = aws_ecr_pull_through_cache_rule.ecr_public[0]
}

moved {
  from = aws_ecr_pull_through_cache_rule.k8s_public
  to   = aws_ecr_pull_through_cache_rule.k8s_public[0]
}

moved {
  from = aws_ecr_pull_through_cache_rule.docker_public
  to   = aws_ecr_pull_through_cache_rule.docker_public[0]
}
