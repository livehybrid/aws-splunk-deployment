data "aws_caller_identity" "current" {
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_eks_cluster" "this" {
  name = "splunk-sok-${local.environment}"
}

data "aws_eks_node_groups" "this" {
  cluster_name = data.aws_eks_cluster.this.name
}

data "aws_eks_node_group" "this" {
  for_each        = data.aws_eks_node_groups.this.names
  cluster_name    = data.aws_eks_cluster.this.name
  node_group_name = each.value
}

locals {
  environment       = lower(var.environment)
  oidc_provider     = trimprefix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider}"
  node_asg_names = flatten([
    for ng in data.aws_eks_node_group.this : [for asg in ng.resources[0].autoscaling_groups : asg.name]
  ])

  # kube-dns ClusterIP: always the 10th address of the cluster's service CIDR.
  # Derived from the live cluster so it stays correct across service-CIDR changes.
  dns_ip = cidrhost(data.aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr, 10)

  #hec_host = "${local.web_host_prefix}-hec.${var.sok_web_external_zone_name}"
}