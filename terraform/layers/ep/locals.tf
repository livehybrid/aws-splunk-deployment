data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "this" {
  name = "splunk-sok-${local.environment}"
}

locals {
  enabled     = var.ep_enabled
  environment = lower(var.environment)
  namespace   = var.ep_namespace

  # Keys come straight from the variable, so for_each stays plan-time known.
  processors = local.enabled ? var.ep_processors : {}
  nlbs       = var.ep_nlb_enabled ? local.processors : {}

  # The chart builds <global.imageRegistry>/splunk/edge-processor:<tag> for the
  # instances AND the principal Job, so one value moves both onto the account
  # layer's ECR pull-through cache (Docker Hub rule) for a VPC with no egress.
  ecr_registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image_registry = var.use_ecr_pullthrough_cache ? "${local.ecr_registry}/docker-public" : "docker.io"

  # Created by the sok layer (storage.tf). ext4 matches the chart's own
  # StorageClass parameters; the queue is small files, not Splunk buckets.
  storage_class = "splunk-gp3-ext4"

  # Same VPC and subnet discovery as the sok layer's ALB (web-ingress.tf): the
  # subnets carry no kubernetes.io/role/*elb tag, so they are passed explicitly.
  vpc_name_tag = var.eks_vpc_name_tag != "" ? var.eks_vpc_name_tag : "splunk-sok-${local.environment}"

  # Internal NLB with no explicit list: the VPC. Internet-facing with no list is
  # refused by the guard in main.tf rather than silently opened to the world.
  nlb_allowed_cidrs = length(var.ep_nlb_allowed_cidrs) > 0 ? var.ep_nlb_allowed_cidrs : (
    var.ep_nlb_internet_facing || length(local.nlbs) == 0 ? [] : [data.aws_vpc.this[0].cidr_block]
  )

  dns_zone = var.ep_dns_zone_name != "" ? var.ep_dns_zone_name : var.sok_web_external_zone_name
  hostnames = {
    for k, p in local.processors : k => (strcontains(p.hostname, ".") ? p.hostname : "${p.hostname}.${local.dns_zone}")
    if p.hostname != ""
  }

  # One entry per listening socket, in the chart's port names. Syslog is TCP and
  # UDP on the same port; the ALB controller turns that into one TCP_UDP listener.
  receivers = concat(
    var.ep_ports.forwarder > 0 ? [{ name = "forwarder", port = var.ep_ports.forwarder, protocol = "TCP" }] : [],
    var.ep_ports.hec > 0 ? [{ name = "hec", port = var.ep_ports.hec, protocol = "TCP" }] : [],
    var.ep_ports.syslog > 0 ? [
      { name = "syslog-tcp", port = var.ep_ports.syslog, protocol = "TCP" },
      { name = "syslog-udp", port = var.ep_ports.syslog, protocol = "UDP" },
    ] : [],
  )

  # The chart's liveness and readiness probes hard-code TCP 8088. Point them at
  # a receiver that is actually enabled, or a deployment without HEC (or with
  # HEC moved) would never go Ready and the NLB would never register a target.
  # HEC first, as the chart intends; syslog always contributes a TCP socket, so
  # the fallback list is never empty once ep_ports passes validation.
  probe_port = var.ep_ports.hec > 0 ? var.ep_ports.hec : [for r in local.receivers : r.port if r.protocol == "TCP"][0]
}
