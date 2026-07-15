###############################################################################
# External Splunk Web access (OPT-IN; gated on var.sok_web_external_enabled).
#
# The default access path to Splunk Web is `kubectl port-forward`, every Splunk
# service is ClusterIP. This file adds ONE internet-facing ALB Ingress with
# host-based routing in front of the UI-serving components selected in
# var.sok_web_external_components (sh/cm/lm/mc, + deployer on SHC shapes), so
# each gets a real HTTPS URL (demos, or where port-forward is impractical).
# Indexers are never exposable, splunkweb is disabled on peers by design.
#
# Hostnames: sh keeps var.sok_web_external_hostname; every other component gets
# <first-label-of-that-hostname>-<component>.<zone> (single label under the
# zone, so the one *.<zone> wildcard cert covers them all).
#
# Requires: the AWS Load Balancer Controller (installed by the eks layer), a
# public ACM cert covering the hostnames, and a Route53 public zone. The shared
# prod subnets are NOT kubernetes.io/role/elb-tagged (tagging them would perturb
# the prod estate's own LB auto-discovery), so the public subnets are passed to
# the controller EXPLICITLY via the `subnets` annotation.
#
# ⚠ Blast radius: this exposes full-admin UIs (dev's credential is env-scoped,
#   var.sok_secret_admin_password_id, so no prod password rides on it, but it
#   is still admin on the cluster). Keep sok_web_external_allowed_cidrs as
#   narrow as the audience allows and TEAR IT DOWN after use (flip the flag off
#   + apply, or destroy the layer). The CM/LM/MC UIs are pure admin surface,
#   think twice before widening their allow-list beyond operators.
# ⚠ Ephemeral shape: the ALB lives in this (nightly-destroyed) layer, so each
#   rebuild yields a NEW ALB DNS name. The Route53 CNAMEs are recreated on every
#   apply from the ALB hostname the controller writes back to the Ingress status
#   (kubernetes_manifest wait{fields} -> aws_route53_record). A URL that is stable
#   across rebuilds wants the external-dns addon (follow-up), not this.
###############################################################################

locals {
  web_external_enabled = var.sok_web_external_enabled

  # Empty allow-list falls back to the operator's trusted_cidrs.
  web_allowed_cidrs = length(var.sok_web_external_allowed_cidrs) > 0 ? var.sok_web_external_allowed_cidrs : var.trusted_cidrs

  # Same VPC discovery as the eks layer (dev overrides eks_vpc_name_tag="prod").
  web_vpc_name_tag = var.eks_vpc_name_tag != "" ? var.eks_vpc_name_tag : var.environment

  # Splunk Web behind the TLS-terminating ALB: it sees plain HTTP on :8000 and,
  # left alone, 303-redirects the browser to http://… and, for the login redirect
  # specifically, to the pod's own socket https://127.0.0.1:8000/…, which the
  # browser can't reach. Two web.conf settings fix it:
  #   tools.proxy.on    = true → build absolute redirect URLs proxy-aware, taking
  #                              the scheme from X-Forwarded-Proto (ALB sends https).
  #   tools.proxy.local = Host → take the HOST from the `Host` header (which the ALB
  #                              preserves) instead of the default X-Forwarded-Host,
  #                              which ALB does NOT send. Without this, Splunk's
  #                              login redirect falls back to 127.0.0.1:8000.
  # Applied to EVERY UI-serving CR whenever the flag is on (regardless of the
  # per-component list) so toggling a component in/out of the ALB never restarts
  # pods, only Ingress rules + DNS records change. Port-forward still works with
  # these set (Host: localhost:8000 resolves to itself).
  web_proxy_conf = [
    {
      key = "web"
      value = {
        directory = "/opt/splunk/etc/system/local"
        content = { settings = {
          "tools.proxy.on"    = "true"
          "tools.proxy.local" = "Host"
        } }
      }
    }
  ]

  web_proxy_defaults = local.web_external_enabled ? {
    defaults = yamlencode({
      splunk = { conf = local.web_proxy_conf }
    })
  } : {}

  # Component -> backing Service. sh follows the shape (Standalone vs SHC);
  # deployer exists only on SHC shapes. Indexers deliberately absent.
  web_component_services = merge(
    {
      sh = var.enable_shc ? "splunk-shc-search-head-service" : "splunk-sh-standalone-service"
      cm = "splunk-cm-cluster-manager-service"
      lm = "splunk-lm-license-manager-service"
      mc = "splunk-mc-monitoring-console-service"
    },
    var.enable_shc ? { deployer = "splunk-shc-deployer-service" } : {}
  )

  web_unknown_components = setsubtract(toset(var.sok_web_external_components), keys(local.web_component_services))

  # sh keeps the canonical hostname; others derive <first-label>-<comp>.<zone>.
  web_host_prefix = split(".", var.sok_web_external_hostname)[0]
  web_component_hosts = local.web_external_enabled ? {
    for c in var.sok_web_external_components :
    c => c == "sh" ? var.sok_web_external_hostname : "${local.web_host_prefix}-${c}.${var.sok_web_external_zone_name}"
  } : {}

  # HEC rides the SAME ALB via a second Ingress in the same group (its backend
  # is HTTPS :8088 with its own health check, and per-Ingress annotations are
  # the only way to give one group member different backend settings).
  hec_external_enabled = local.web_external_enabled && var.sok_hec_external_enabled
  hec_host             = "${local.web_host_prefix}-hec.${var.sok_web_external_zone_name}"

  # One ALB for everything: both Ingresses join this group and pin the same
  # load-balancer-name, so the controller merges their rules onto one ALB.
  web_alb_group = "splunk-sok-${var.environment}-web"
}

data "aws_vpc" "web" {
  count = local.web_external_enabled ? 1 : 0
  tags  = { Name = local.web_vpc_name_tag, project = "splunk" }
}

# The public subnets (default-{a,b,c}) for the internet-facing ALB, discovered
# by name rather than auto-discovered (the shared subnets carry no elb role tag).
data "aws_subnets" "web_public" {
  count = local.web_external_enabled ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.web[0].id]
  }
  filter {
    name   = "tag:Name"
    values = ["default-a", "default-b", "default-c"]
  }
}

data "aws_route53_zone" "web" {
  count        = local.web_external_enabled ? 1 : 0
  name         = "${var.sok_web_external_zone_name}."
  private_zone = false
}

data "aws_acm_certificate" "web" {
  count       = local.web_external_enabled && var.sok_web_external_certificate_arn == "" ? 1 : 0
  domain      = "*.${var.sok_web_external_zone_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  web_cert_arn = local.web_external_enabled ? (
    var.sok_web_external_certificate_arn != "" ? var.sok_web_external_certificate_arn : data.aws_acm_certificate.web[0].arn
  ) : ""
  web_subnet_ids = local.web_external_enabled ? data.aws_subnets.web_public[0].ids : []
}

resource "kubernetes_manifest" "web_ingress" {
  count = local.web_external_enabled ? 1 : 0

  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "splunk-web"
      namespace = local.namespace
      annotations = {
        # group.name lets the HEC Ingress share this ALB (per-Ingress backend
        # annotations differ; group-level ones below must match exactly).
        "alb.ingress.kubernetes.io/group.name"              = local.web_alb_group
        "alb.ingress.kubernetes.io/group.order"             = "10"
        "alb.ingress.kubernetes.io/scheme"                  = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"             = "ip"
        "alb.ingress.kubernetes.io/load-balancer-name"      = "splunk-sok-${var.environment}-web"
        "alb.ingress.kubernetes.io/subnets"                 = join(",", local.web_subnet_ids)
        "alb.ingress.kubernetes.io/listen-ports"            = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
        "alb.ingress.kubernetes.io/ssl-redirect"            = "443"
        "alb.ingress.kubernetes.io/certificate-arn"         = local.web_cert_arn
        "alb.ingress.kubernetes.io/inbound-cidrs"           = join(",", local.web_allowed_cidrs)
        "alb.ingress.kubernetes.io/backend-protocol"        = "HTTP"
        "alb.ingress.kubernetes.io/healthcheck-port"        = "8000"
        "alb.ingress.kubernetes.io/healthcheck-path"        = "/en-US/account/login"
        "alb.ingress.kubernetes.io/success-codes"           = "200,303"
        "alb.ingress.kubernetes.io/target-group-attributes" = "stickiness.enabled=true,stickiness.type=lb_cookie,deregistration_delay.timeout_seconds=30"
        "alb.ingress.kubernetes.io/tags"                    = "environment=${var.environment},project=splunk,component=sok-web"
      }
    }
    spec = {
      ingressClassName = "alb"
      # One rule per exposed component, host-based routing on the single ALB.
      rules = [for c, host in local.web_component_hosts : {
        host = host
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = local.web_component_services[c]
                port = { number = 8000 }
              }
            }
          }]
        }
      }]
    }
  }

  # Block the apply until the AWS Load Balancer Controller provisions the ALB and
  # writes its DNS name into the Ingress status, that hostname is what the Route53
  # records below point at. Replaces the old sok-web-dns.sh poll-in-local-exec.
  wait {
    fields = {
      "status.loadBalancer.ingress[0].hostname" = "^.+$"
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.web_unknown_components) == 0
      error_message = "sok_web_external_components contains unknown/inapplicable keys: ${join(", ", local.web_unknown_components)}. Valid here: ${join(", ", sort(keys(local.web_component_services)))} (deployer needs enable_shc; indexers are never exposable)."
    }
  }

  depends_on = [kubectl_manifest.search_head]
}

# HEC on the shared ALB (sok_hec_external_enabled): host rule -> the indexer
# service's HTTPS :8088. Its own Ingress because backend-protocol/health-check
# annotations are per-Ingress. Verified guidance: ALB-fronting HEC is
# supported, Firehose gained ALB support 2024-01 and REQUIRES a CA-signed cert
# matching the DNS name (exactly what the ALB+ACM give; raw :8088 is
# self-signed); NLB is NOT supported for Firehose->HEC. Stickiness is 7-day
# lb_cookie: required for useACK tokens (ack polls must hit the receiving
# node); harmless for plain senders.
resource "kubernetes_manifest" "hec_ingress" {
  count = local.hec_external_enabled ? 1 : 0

  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "splunk-hec"
      namespace = local.namespace
      annotations = {
        "alb.ingress.kubernetes.io/group.name"  = local.web_alb_group
        "alb.ingress.kubernetes.io/group.order" = "20"
        # Group-level annotations, must MATCH the web Ingress exactly.
        "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"        = "ip"
        "alb.ingress.kubernetes.io/load-balancer-name" = "splunk-sok-${var.environment}-web"
        "alb.ingress.kubernetes.io/subnets"            = join(",", local.web_subnet_ids)
        "alb.ingress.kubernetes.io/listen-ports"       = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
        "alb.ingress.kubernetes.io/certificate-arn"    = local.web_cert_arn
        "alb.ingress.kubernetes.io/inbound-cidrs"      = join(",", local.web_allowed_cidrs)
        # Per-Ingress backend settings (why HEC is a separate Ingress).
        "alb.ingress.kubernetes.io/backend-protocol"        = "HTTPS"
        "alb.ingress.kubernetes.io/healthcheck-port"        = "8088"
        "alb.ingress.kubernetes.io/healthcheck-protocol"    = "HTTPS"
        "alb.ingress.kubernetes.io/healthcheck-path"        = "/services/collector/health"
        "alb.ingress.kubernetes.io/success-codes"           = "200"
        "alb.ingress.kubernetes.io/target-group-attributes" = "stickiness.enabled=true,stickiness.type=lb_cookie,stickiness.lb_cookie.duration_seconds=604800,deregistration_delay.timeout_seconds=30"
        # tags are GROUP-scoped: every member Ingress must carry the IDENTICAL
        # string or the controller fails the whole group model ("conflicting
        # tag component"). Keep in lockstep with the web Ingress.
        "alb.ingress.kubernetes.io/tags" = "environment=${var.environment},project=splunk,component=sok-web"
      }
    }
    spec = {
      ingressClassName = "alb"
      rules = [{
        host = local.hec_host
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "splunk-idxc-indexer-service"
                port = { number = 8088 }
              }
            }
          }]
        }
      }]
    }
  }

  wait {
    fields = {
      "status.loadBalancer.ingress[0].hostname" = "^.+$"
    }
  }

  depends_on = [kubernetes_manifest.web_ingress]
}

# The ALB is provisioned by the controller AFTER the Ingress and shared by both
# Ingresses (same group.name), so its DNS name is unknown until apply time. The
# kubernetes_manifest `wait` blocks above hold the apply until the controller
# writes that name into status.loadBalancer.ingress[0].hostname; these records
# then point the per-component CNAMEs at it. Recreated each rebuild (new ALB
# name); external-dns would own this in a durable, always-on setup (follow-up).
resource "aws_route53_record" "web" {
  for_each = local.web_component_hosts

  zone_id = data.aws_route53_zone.web[0].zone_id
  name    = each.value
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_manifest.web_ingress[0].object.status.loadBalancer.ingress[0].hostname]
}

resource "aws_route53_record" "hec" {
  count = local.hec_external_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.web[0].zone_id
  name    = local.hec_host
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_manifest.hec_ingress[0].object.status.loadBalancer.ingress[0].hostname]
}
