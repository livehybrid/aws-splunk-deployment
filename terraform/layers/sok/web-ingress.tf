###############################################################################
# External Splunk Web access (OPT-IN; gated on var.sok_web_external_enabled).
#
# The default access path to Splunk Web is `kubectl port-forward`, every Splunk
# service is ClusterIP. This file adds ONE internet-facing ALB Ingress with
# host-based routing in front of the UI-serving components selected in
# var.sok_web_external_components (sh-<key>/shc-<key>/shc-<key>-deployer/cm/lm/
# mc), so each gets a real HTTPS URL (demos, or where port-forward is
# impractical). Indexers are never exposable, splunkweb is disabled on peers.
#
# Hostnames: var.sok_web_canonical_component takes var.sok_web_external_hostname
# itself; every other component gets <first-label-of-that-hostname>-<component
# minus its sh-/shc- prefix>.<zone>, overridable per component via
# var.sok_web_external_component_hostnames. Always a SINGLE label under the
# zone, so the one *.<zone> wildcard cert covers them all. Two components
# resolving to the same name fails the plan (terraform_data.web_component_guard),
# Route53 cannot hold two CNAMEs of one name.
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
  web_vpc_name_tag = var.eks_vpc_name_tag != "" ? var.eks_vpc_name_tag : "splunk-sok-${local.environment}"

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
        # NOT system/local: a conf entry there makes splunk-ansible delete the
        # whole file first. See the overlay_app note in crs.tf.
        directory = local.overlay_app_dir
        content = { settings = {
          "tools.proxy.on"    = "true"
          "tools.proxy.local" = "Host"
        } }
      }
    }
  ]

  # NOTE: there is deliberately no web_proxy_defaults local here any more. It used
  # to wrap web_proxy_conf into a `defaults` blob and evaluate to {} when the ALB
  # was off, which meant a CR merging it got NO defaults at all in that case. Now
  # that every CR must carry declarative_admin_password regardless of the ALB, the
  # blobs are built in crs.tf (cr_defaults / sh_defaults / shc_defaults) and this
  # file exports only the conf fragment.

  # Component -> backing Service. Dynamically includes all named standalone SHs
  # and SHCs from local.sh_map / local.shc_map. Keys in sok_web_external_components:
  #   sh-<key>            -> standalone SH service
  #   shc-<key>           -> SHC search head service
  #   shc-<key>-deployer  -> SHC deployer service
  #   cm, lm, mc          -> fixed management services
  web_component_services = merge(
    {
      cm = "splunk-cm-cluster-manager-service"
      lm = "splunk-lm-license-manager-service"
      mc = "splunk-mc-monitoring-console-service"
    },
    # Stoker/Regulator are not Splunk CRs: their Services are created by their
    # respective .tf files and only exist when the enable flag is true. Listing
    # them here unconditionally keeps them valid component keys (so the
    # unknown-component guard does not reject them); terraform_data.*_guard in
    # each file is what fails the plan if they are exposed while disabled.
    { stoker = "stoker" },
    { regulator = "regulator" },
    { for k in keys(local.sh_map) : "sh-${k}" => "splunk-sh-${k}-standalone-service" },
    { for k in keys(local.shc_map) : "shc-${k}" => "splunk-shc-${k}-search-head-service" },
    { for k in keys(local.shc_map) : "shc-${k}-deployer" => "splunk-shc-${k}-deployer-service" },
  )

  # Backend port per component. Every Splunk UI serves splunkweb on 8000; Stoker
  # is a FastAPI app on 8080. Hardcoding 8000 in the rule builder sent the ALB
  # health check and every request to a port Stoker does not listen on, so the
  # target group never came up healthy.
  web_component_ports = merge(
    { for c in var.sok_web_external_components : c => 8000 },
    { stoker = 8080 },
    { regulator = 8080 },
  )

  web_unknown_components = setsubtract(toset(var.sok_web_external_components), keys(local.web_component_services))

  # One component answers on sok_web_external_hostname itself; every other one
  # derives <first-label>-<comp>.<zone>.
  web_host_prefix = split(".", var.sok_web_external_hostname)[0]

  # Auto rule (unchanged): the canonical hostname goes to the sole standalone SH
  # only when there is exactly one SH and no SHC, the legacy single-SH shape.
  # In any other shape nothing may silently steal the canonical URL, so every
  # component gets a derived name and the bare hostname stays unbound.
  web_canonical_auto = (length(local.sh_map) == 1 && length(local.shc_map) == 0) ? "sh-${keys(local.sh_map)[0]}" : ""

  # var.sok_web_canonical_component overrides that: name any component (sh-<key>,
  # shc-<key>, shc-<key>-deployer, cm, lm, mc) and it takes the bare hostname.
  # Needed because the auto rule leaves multi-SH / SHC shapes with no answer on
  # sok_web_external_hostname at all, so the obvious URL 404s. Guarded below:
  # the named component must also be exposed, or it would get no ALB rule.
  web_canonical_component = var.sok_web_canonical_component != "" ? var.sok_web_canonical_component : local.web_canonical_auto

  # Host label per component. The sh-/shc- ROLE PREFIX is dropped so the URL
  # reads sok-dev-ops rather than sok-dev-sh-ops, but only the prefix: taking
  # split("-", c)[1] instead maps BOTH "shc-default" and "shc-default-deployer"
  # to "default", which collides on one hostname (two CNAMEs of the same name
  # in Route53, two ALB rules for one host). trimprefix is ordered shc- before
  # sh- so the longer prefix wins. Collisions are still possible across roles
  # (an SH and an SHC both keyed "default" both label to "default"), so
  # web_duplicate_hosts below fails the plan rather than letting it through.
  web_component_label = {
    for c in var.sok_web_external_components : c => trimprefix(trimprefix(c, "shc-"), "sh-")
  }

  # Per-component hostname, in precedence order:
  #   1. sok_web_external_component_hostnames[c] — explicit. A bare label goes
  #      under the zone; a value containing a dot is used as a full FQDN (which
  #      then has to be covered by the cert yourself, a *.<zone> wildcard covers
  #      exactly one label).
  #   2. sok_web_external_hostname — the canonical component.
  #   3. <first-label>-<label>.<zone> — derived.
  web_component_override = {
    for c in var.sok_web_external_components : c => lookup(var.sok_web_external_component_hostnames, c, "")
  }

  web_component_hosts = local.web_external_enabled ? {
    for c in var.sok_web_external_components : c => (
      local.web_component_override[c] != "" ? (
        strcontains(local.web_component_override[c], ".")
        ? local.web_component_override[c]
        : "${local.web_component_override[c]}.${var.sok_web_external_zone_name}"
        ) : c == local.web_canonical_component ? var.sok_web_external_hostname : (
        "${local.web_host_prefix}-${local.web_component_label[c]}.${var.sok_web_external_zone_name}"
      )
    )
  } : {}

  # Every name this layer will put in Route53, HEC included (a component
  # labelled "hec" would collide with the HEC record). Inverted to
  # host -> [components], so anything with more than one claimant is a clash.
  web_all_hosts       = merge(local.web_component_hosts, local.hec_external_enabled ? { hec = local.hec_host } : {})
  web_duplicate_hosts = { for host, cs in { for c, h in local.web_all_hosts : h => c... } : host => sort(cs) if length(cs) > 1 }

  # HEC rides the SAME ALB via a second Ingress in the same group (its backend
  # is HTTPS :8088 with its own health check, and per-Ingress annotations are
  # the only way to give one group member different backend settings).
  hec_external_enabled = local.web_external_enabled && var.sok_hec_external_enabled
  hec_host             = "${local.web_host_prefix}-hec.${var.sok_web_external_zone_name}"

  # HEC fronts kubernetes_service_v1.hec_indexers below, NOT a per-CR operator
  # service. The operator names its indexer service after the CR, so the shape
  # changes it: single-site is one CR "idxc" (splunk-idxc-indexer-service),
  # multisite is one CR per site (splunk-idxc-site1-indexer-service, ...).
  # Hardcoding the single-site name meant that under multisite the HEC Ingress
  # pointed at a Service that does not exist, and because both Ingresses share
  # group.name the controller failed the WHOLE group's model, taking every
  # Splunk Web rule down with it. Our own Service is shape-independent AND spans
  # every site, which no operator-created service does here.
  # one(), not [0]: the Service is count-gated on hec_external_enabled, and a
  # bare [0] is an index-out-of-range the moment anything evaluates this local
  # with HEC off (prod's default). one() yields null instead, and the only
  # consumer is the equally-gated HEC Ingress.
  hec_backend_service = one(kubernetes_service_v1.hec_indexers[*].metadata[0].name)

  # One ALB for everything: both Ingresses join this group and pin the same
  # load-balancer-name, so the controller merges their rules onto one ALB.
  web_alb_group = "splunk-sok-${local.environment}-web"
}

# Plan-time guard on the component list. Without it a component with no backing
# service fails at APPLY, deep inside the Ingress body, as a bare
# "Invalid index: The given key does not identify an element in this collection
# value" from local.web_component_services[c], naming neither the bad key nor
# the valid ones. local.web_unknown_components existed for exactly this and was
# never consumed. terraform_data is builtin and inert; the preconditions are
# evaluated at plan (same pattern as _shared/checks.tf).
resource "terraform_data" "web_component_guard" {
  count = local.web_external_enabled ? 1 : 0

  input = var.sok_web_external_components

  lifecycle {
    precondition {
      condition     = length(local.web_unknown_components) == 0
      error_message = "sok_web_external_components names ${join(", ", sort(local.web_unknown_components))}, which has no backing Splunk service in this shape. Valid keys: ${join(", ", sort(keys(local.web_component_services)))}."
    }
    precondition {
      condition     = var.sok_web_canonical_component == "" || contains(var.sok_web_external_components, var.sok_web_canonical_component)
      error_message = "sok_web_canonical_component is '${var.sok_web_canonical_component}' but that component is not in sok_web_external_components, so it would get no ALB rule and sok_web_external_hostname would resolve to nothing. Add it to the list, or clear the setting to fall back to the automatic choice."
    }
    # The one that catches the shc-default / shc-default-deployer clash.
    precondition {
      condition     = length(local.web_duplicate_hosts) == 0
      error_message = "More than one component resolves to the same ALB hostname: ${join("; ", [for h, cs in local.web_duplicate_hosts : "${h} <- ${join(", ", cs)}"])}. Route53 cannot hold two CNAMEs of the same name and the ALB would get two rules for one host. Give one of them an explicit name in sok_web_external_component_hostnames."
    }
    precondition {
      condition     = length(setsubtract(keys(var.sok_web_external_component_hostnames), var.sok_web_external_components)) == 0
      error_message = "sok_web_external_component_hostnames names ${join(", ", sort(setsubtract(keys(var.sok_web_external_component_hostnames), var.sok_web_external_components)))}, which is not exposed via sok_web_external_components, so the override would be silently ignored."
    }
    precondition {
      condition     = var.sok_web_canonical_component == "" || lookup(var.sok_web_external_component_hostnames, var.sok_web_canonical_component, "") == ""
      error_message = "'${var.sok_web_canonical_component}' is both sok_web_canonical_component (which gives it sok_web_external_hostname) and has an entry in sok_web_external_component_hostnames. Pick one: the explicit override would win and the canonical setting would do nothing."
    }
  }
}

data "aws_vpc" "web" {
  count = local.web_external_enabled ? 1 : 0
  tags = {
    Name = local.web_vpc_name_tag
  }
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

# Destroy-ordering gate for the ALB controller's finalizers.
#
# THE BUG THIS EXISTS TO PREVENT. Both Ingresses carry the finalizer
# group.ingress.k8s.aws/<group>, and the TargetGroupBindings the controller
# creates carry elbv2.k8s.aws/resources. Only the controller can clear them.
# kubectl_manifest issues its delete and returns without waiting (see the note
# on web_ingress), so on destroy Terraform would tear the controller down while
# those finalizers were still pending. Nothing was then left to clear them, and
# the result was both silent and expensive:
#
#   * kubernetes_namespace_v1.splunk hung in Terminating until the operation
#     timed out ("context deadline exceeded"), failing the destroy part way;
#   * the ALB and all seven target groups survived in AWS, still billing, which
#     is the exact opposite of what a teardown is for. Nothing reported this:
#     the namespace was the thing that looked stuck, not the load balancer.
#
# HOW THIS FIXES IT. This resource sits BETWEEN the ingresses and everything the
# controller needs in order to do its job: the ingresses depend on it, and it
# depends on the controller's Helm release AND on the IAM role and policy that
# give the controller its AWS permissions. Terraform destroys in reverse
# dependency order, so the sequence becomes
#
#   ingresses -> this gate -> controller (deployment, role, policy)
#
# and the gate's destroy-time provisioner runs after the deletes have been
# issued and while the controller is still running AND still authorised. It
# waits for the ALB to actually disappear, which is the observable proof that
# the controller finalized the Ingresses and tore down its AWS resources.
#
# THE IAM DEPENDENCY IS NOT OPTIONAL, and leaving it out is how the first
# version of this gate failed. Keeping the controller's POD alive is not enough:
# Terraform destroyed aws_iam_role_policy.alb_controller before it even issued
# the Ingress deletes, so by the time the controller was asked to tear the ALB
# down it had no permissions at all. Its own log says exactly this, and it is
# worth quoting because the shape of it is so easy to miss:
#
#   "successfully built model","model":"{"id":"splunk-sok-dev-web","resources":{}}"
#   error ... AccessDenied ... not authorized to perform: ec2:DescribeSecurityGroups
#
# It worked out precisely what to delete and had been stripped of the right to
# do it. The ALB and its seven target groups survived, still billing, and the
# gate simply made that take ten minutes instead of none.
#
# It watches the ALB with the AWS CLI rather than the finalizers with kubectl,
# because a destroy provisioner cannot assume a kubeconfig is present (CI, a
# different operator, a rebuilt workstation), and null_resource.alb_ready below
# already proves the AWS CLI is available in this layer.
#
# on_failure = continue is deliberate: if the wait exceeds its budget, a
# teardown that refuses to finish is worse than one that proceeds and leaves a
# sweep behind. The message says exactly what to check.
resource "null_resource" "ingress_finalizer_gate" {
  count = local.web_external_enabled ? 1 : 0

  # A destroy provisioner may only read self.triggers, never variables.
  triggers = {
    alb_name = "splunk-sok-${local.environment}-web"
    region   = var.region
    profile  = var.profile
  }

  # All three: the controller has to be running, and still hold its role and
  # its policy, for the whole time this gate is waiting on it.
  depends_on = [
    helm_release.alb_controller,
    aws_iam_role.alb_controller,
    aws_iam_role_policy.alb_controller,
  ]

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOF
      set -u
      NAME='${self.triggers.alb_name}'
      REGION='${self.triggers.region}'
      PROFILE_ARG=''
      if [ -n '${self.triggers.profile}' ]; then PROFILE_ARG='--profile ${self.triggers.profile}'; fi
      echo "Waiting for the ALB controller to finalize $NAME before it is torn down..."
      for i in $(seq 1 60); do
        # Distinguish "gone" from "the call failed". Treating any non-zero exit
        # as success would make a missing CLI, a bad profile or an expired
        # credential look exactly like a completed teardown, and silently turn
        # this gate off at the moment it matters most.
        ERR="$(aws elbv2 describe-load-balancers --names "$NAME" --region "$REGION" \
               $PROFILE_ARG 2>&1 >/dev/null)" && STATUS=found || STATUS=error
        if [ "$STATUS" = "error" ]; then
          case "$ERR" in
            *LoadBalancerNotFound*)
              echo "ALB $NAME has gone; the Ingress finalizers cleared."
              exit 0
              ;;
            *)
              echo "cannot tell whether $NAME still exists: $ERR" >&2
              ;;
          esac
        fi
        sleep 10
      done
      echo "WARNING: $NAME still exists after 10 minutes." >&2
      echo "The controller is about to go with finalizers outstanding." >&2
      echo "If the namespace then hangs in Terminating: remove the load balancer" >&2
      echo "and its target groups in AWS, then clear the finalizers on the" >&2
      echo "ingresses and targetgroupbindings in that namespace." >&2
    EOF
  }
}

resource "kubectl_manifest" "web_ingress" {
  count = local.web_external_enabled ? 1 : 0

  # kubectl_manifest doesn't block on finalizers during delete — it issues the
  # delete call and moves on, avoiding the 10-minute timeout that kubernetes_manifest
  # hits when the ALB controller is already gone and can't clear its finalizer.
  yaml_body = yamlencode({
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
        "alb.ingress.kubernetes.io/scheme"                  = var.sok_alb_is_internet_facing ? "internet-facing" : "internal"
        "alb.ingress.kubernetes.io/target-type"             = "ip"
        "alb.ingress.kubernetes.io/load-balancer-name"      = "splunk-sok-${local.environment}-web"
        "alb.ingress.kubernetes.io/subnets"                 = join(",", local.web_subnet_ids)
        "alb.ingress.kubernetes.io/listen-ports"            = jsonencode([{ HTTPS = 443 }])
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
      rules = [for c, host in local.web_component_hosts : {
        host = host
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              # The COMPONENT KEY (sh-ops, lm, shc-default-deployer) is only a
              # selector; the backend must be the operator's service name for
              # it. `name = c` sends the ALB looking for a Service literally
              # called "lm" and every rule in the group fails to resolve, which
              # fails the whole model, not just that rule.
              service = {
                name = local.web_component_services[c]
                port = { number = local.web_component_ports[c] }
              }
            }
          }]
        }
      }]
    }
  })

  wait_for_rollout = false


  depends_on = [kubectl_manifest.search_head, kubectl_manifest.search_head_cluster, helm_release.alb_controller, null_resource.ingress_finalizer_gate]
}

# Poll via the AWS CLI (no kubeconfig required) until the ALB controller has
# provisioned the ALB and it reaches the `active` state. Both the web and HEC
# Ingresses share one ALB (same group.name / load-balancer-name), so a single
# wait covers both. Uses null_resource rather than terraform_data because the
# null provider is already locked; the exec needs no kubectl at all — just the
# AWS credentials already in scope for the apply.
resource "null_resource" "alb_ready" {
  count = local.web_external_enabled ? 1 : 0

  triggers = {
    # Re-run whenever the Ingress is recreated (new cluster = new ALB name).
    ingress_uid = kubectl_manifest.web_ingress[0].uid
  }

  provisioner "local-exec" {
    command = <<-EOF
      echo "Waiting for ALB splunk-sok-${local.environment}-web to become active..."
      for i in $(seq 1 60); do
        STATE=$(aws elbv2 describe-load-balancers \
          --names "splunk-sok-${local.environment}-web" \
          --region ${var.region} \
          --profile ${var.profile} \
          --query 'LoadBalancers[0].State.Code' \
          --output text 2>/dev/null)
        if [ "$STATE" = "active" ]; then echo "ALB active"; exit 0; fi
        echo "  state=$${STATE:-not-found}, retrying ($i/60)..."
        sleep 10
      done
      echo "Timed out waiting for ALB to become active" && exit 1
    EOF
  }

  depends_on = [kubectl_manifest.web_ingress]
}

# Read the ALB DNS name via AWS API once it's active. The name is deterministic
# (set in the load-balancer-name annotation) so this data source resolves
# correctly without needing to read it from the Ingress status via kubectl.
data "aws_lb" "web" {
  count      = local.web_external_enabled ? 1 : 0
  name       = "splunk-sok-${local.environment}-web"
  depends_on = [null_resource.alb_ready]
}

# HEC on the shared ALB (sok_hec_external_enabled): host rule -> the indexer
# service's HTTPS :8088. Its own Ingress because backend-protocol/health-check
# annotations are per-Ingress. Verified guidance: ALB-fronting HEC is
# supported, Firehose gained ALB support 2024-01 and REQUIRES a CA-signed cert
# matching the DNS name (exactly what the ALB+ACM give; raw :8088 is
# self-signed); NLB is NOT supported for Firehose->HEC. Stickiness is 7-day
# lb_cookie: required for useACK tokens (ack polls must hit the receiving
# node); harmless for plain senders.
# One Service covering EVERY indexer peer, across every site, so the HEC ALB has
# a single target group that round-robins the whole tier. A k8s Ingress path
# takes exactly one backend Service, and the operator gives us no service that
# spans sites: it only drops the instance label from an IndexerCluster service's
# selector (making it cover all parts) when that CR carries no clusterManagerRef,
# and every CR here sets one.
#
# The selector is the operator's own labelling contract, not guesswork.
# splcommon.GetLabels writes app.kubernetes.io/part-of = "splunk-<partOf>-<component>",
# and enterprise.getSplunkService sets partOf to the CLUSTER MANAGER REF NAME for
# every child part of a multisite cluster. So all peers of both sites carry
# part-of=splunk-cm-indexer, and so does the single-site "idxc" CR (it also refs
# cm), which is why this one Service is correct for both shapes with no branch.
#
# ⚠ Tied to the ClusterManager CR being named "cm" (crs.tf). Rename that and this
# selector silently matches nothing: the ALB target group empties and HEC 503s.
resource "kubernetes_service_v1" "hec_indexers" {
  count = local.hec_external_enabled ? 1 : 0

  metadata {
    name      = "splunk-hec-indexers"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "indexer"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/managed-by" = "splunk-operator"
      "app.kubernetes.io/component"  = "indexer"
      "app.kubernetes.io/name"       = "indexer"
      "app.kubernetes.io/part-of"    = "splunk-cm-indexer"
    }

    port {
      name        = "hec"
      port        = 8088
      target_port = 8088
      protocol    = "TCP"
    }
  }

  depends_on = [
    kubernetes_namespace_v1.splunk,
    helm_release.alb_controller,
  ]
}

resource "kubectl_manifest" "hec_ingress" {
  count = local.hec_external_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "splunk-hec"
      namespace = local.namespace
      annotations = {
        "alb.ingress.kubernetes.io/group.name"  = local.web_alb_group
        "alb.ingress.kubernetes.io/group.order" = "20"
        # Group-level annotations, must MATCH the web Ingress exactly.
        "alb.ingress.kubernetes.io/scheme"             = var.sok_alb_is_internet_facing ? "internet-facing" : "internal"
        "alb.ingress.kubernetes.io/target-type"        = "ip"
        "alb.ingress.kubernetes.io/load-balancer-name" = "splunk-sok-${local.environment}-web"
        "alb.ingress.kubernetes.io/subnets"            = join(",", local.web_subnet_ids)
        "alb.ingress.kubernetes.io/listen-ports"       = jsonencode([{ HTTPS = 443 }])
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
                name = local.hec_backend_service
                port = { number = 8088 }
              }
            }
          }]
        }
      }]
    }
  })

  wait_for_rollout = false

  depends_on = [kubectl_manifest.web_ingress, helm_release.alb_controller, null_resource.ingress_finalizer_gate]
}

# HEC shares the same ALB as the web Ingress — null_resource.alb_ready above
# already waits for it. No separate poll needed.


# The ALB is provisioned by the controller after the Ingress and shared by both
# Ingresses (same group.name / load-balancer-name). data.aws_lb.web reads its
# DNS name once null_resource.alb_ready confirms it's active.
# Recreated each rebuild (new ALB name each cluster); external-dns would own
# this in a durable, always-on setup (follow-up).
resource "aws_route53_record" "web" {
  for_each = local.web_component_hosts
  zone_id  = data.aws_route53_zone.web[0].zone_id
  name     = each.value
  type     = "CNAME"
  ttl      = 60
  records  = [data.aws_lb.web[0].dns_name]
}

resource "aws_route53_record" "hec" {
  count = local.hec_external_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.web[0].zone_id
  name    = local.hec_host
  type    = "CNAME"
  ttl     = 60
  records = [data.aws_lb.web[0].dns_name]
}

output "web_alb_hostname" {
  value = one(data.aws_lb.web[*].dns_name)
}

output "web_component_urls" {
  value = local.web_component_hosts
}