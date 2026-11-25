###############################################################################
# Splunk Edge Processor on EKS: one splunk/edge-processor release per entry in
# ep_processors, each behind its own NLB.
#
# What the chart creates per release (1.0.3):
#   - a StatefulSet of instances, each with its own event-queue PVC and a small
#     instance-identity PVC, so a restarted pod comes back as the same instance
#     with its queue intact;
#   - a one-off Job that runs `eptools setup` with the TOKEN and writes the
#     resulting service principal into a Secret every instance mounts;
#   - a ClusterIP Service on the receiver ports, an HPA and a PDB.
#
# The Job is not a Helm hook and nothing waits for it: instances sit in
# ContainerCreating until its Secret appears, then take up to 30 minutes (the
# chart's startup probe budget) to open their metrics endpoint. So the release
# is applied with wait = false, and outputs.tf prints the commands that show
# whether it came up.
###############################################################################

resource "terraform_data" "ep_guard" {
  count = local.enabled ? 1 : 0

  input = keys(var.ep_processors)

  lifecycle {
    precondition {
      condition     = length(var.ep_processors) > 0
      error_message = "ep_enabled is true but ep_processors is empty. Add one entry per Edge Processor (group_id + token_secret_id) from the control plane's Kubernetes install command."
    }
    precondition {
      condition     = var.ep_tenant != ""
      error_message = "ep_tenant is empty. Copy TENANT from the control plane's Kubernetes install command (Edge Processors -> the processor -> Actions -> Install/Uninstall -> Instance type Kubernetes)."
    }
    precondition {
      condition     = !var.ep_nlb_enabled || !var.ep_nlb_internet_facing || length(var.ep_nlb_allowed_cidrs) > 0
      error_message = "ep_nlb_internet_facing is true but ep_nlb_allowed_cidrs is empty. Set the sender CIDRs explicitly (use [\"0.0.0.0/0\"] only if the receivers really must be open to the internet)."
    }
    precondition {
      condition     = var.ep_nlb_enabled || length(local.hostnames) == 0
      error_message = "ep_processors sets a hostname but ep_nlb_enabled is false: the record would have nothing to point at."
    }
    precondition {
      condition     = length(local.hostnames) == 0 || local.dns_zone != ""
      error_message = "ep_processors sets a hostname but neither ep_dns_zone_name nor sok_web_external_zone_name is set."
    }
    precondition {
      condition     = alltrue([for h in values(local.hostnames) : endswith(h, ".${local.dns_zone}")])
      error_message = "Every ep_processors hostname must sit inside the zone ${local.dns_zone}, where its record is created."
    }
  }
}

# Without an egress allow-list, instances reach the control plane only if it is
# on :443 (Splunk Cloud). A Splunk Enterprise control plane on :8089, or
# indexers outside the cluster, are dropped by the policy below.
check "ep_egress_reaches_control_plane" {
  assert {
    condition     = !local.enabled || !var.sok_network_policies_enabled || length(var.ep_egress_cidrs) > 0
    error_message = "sok_network_policies_enabled is on and ep_egress_cidrs is empty, so Edge Processor instances can reach only DNS, :443, in-cluster Services and the splunk namespace. Fine for a Splunk Cloud control plane sending to the SOK indexers; a Splunk Enterprise control plane on :8089 or off-cluster destinations need their CIDRs in ep_egress_cidrs."
  }
}

data "aws_secretsmanager_secret_version" "token" {
  for_each  = local.processors
  secret_id = each.value.token_secret_id
}

data "aws_vpc" "this" {
  count = length(local.nlbs) > 0 ? 1 : 0
  tags = {
    Name = local.vpc_name_tag
  }
}

data "aws_subnets" "nlb" {
  count = length(local.nlbs) > 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this[0].id]
  }
  filter {
    name   = "tag:Name"
    values = ["default-a", "default-b", "default-c"]
  }
}

resource "kubernetes_namespace_v1" "ep" {
  count = local.enabled ? 1 : 0

  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/part-of" = "splunk-edge-processor"
    }
  }

  depends_on = [terraform_data.ep_guard]
}

locals {
  ep_values = { for k, p in local.processors : k => {
    global = { imageRegistry = local.image_registry }

    # Short, stable names: StatefulSet ep-<key>, pods ep-<key>-N.
    fullnameOverride = "ep-${k}"

    config = {
      ENV      = var.ep_env
      REGION   = var.ep_region
      TENANT   = var.ep_tenant
      GROUP_ID = p.group_id
      # TOKEN is passed with set_sensitive below.
    }

    # The chart defaults every release to one Secret name, so two processors in
    # one namespace would overwrite each other's principal. Give each its own.
    auth = { servicePrincipal = { principalSecretName = "ep-${k}-principal" } }

    ports = {
      forwarder = { enabled = var.ep_ports.forwarder > 0, port = var.ep_ports.forwarder > 0 ? var.ep_ports.forwarder : 9997 }
      hec       = { enabled = var.ep_ports.hec > 0, port = var.ep_ports.hec > 0 ? var.ep_ports.hec : 8088 }
      syslog = {
        enabled = var.ep_ports.syslog > 0
        ports = [
          { port = var.ep_ports.syslog > 0 ? var.ep_ports.syslog : 10514, protocol = "TCP", name = "syslog-tcp" },
          { port = var.ep_ports.syslog > 0 ? var.ep_ports.syslog : 10514, protocol = "UDP", name = "syslog-udp" },
        ]
      }
    }

    deployment = { replicaCount = p.replicas }

    container = {
      # Helm merges maps, so the chart's EP_CONTAINER / ORCHESTRATOR and its
      # ephemeral-storage requests survive alongside these.
      env = var.ep_extra_env
      resources = {
        requests = { cpu = var.ep_resources.cpu_request, memory = var.ep_resources.memory_request }
        limits   = { cpu = var.ep_resources.cpu_limit, memory = var.ep_resources.memory_limit }
      }
      probes = {
        livenessProbe  = { tcpSocket = { port = local.probe_port } }
        readinessProbe = { tcpSocket = { port = local.probe_port } }
      }
    }

    persistence = {
      storageClass = local.storage_class
      eventQueue   = { size = "${p.queue_size_gib}Gi" }
    }

    autoscaling = {
      enabled     = var.ep_autoscaling_enabled
      maxReplicas = p.max_replicas
    }

    # The chart's minAvailable 2 suits its 3 replicas. At 2 it would block every
    # voluntary eviction (node rolls, the nightly teardown); at 1 it can only
    # ever block, so it is dropped.
    podDisruptionBudget = {
      enabled      = p.replicas >= 2
      minAvailable = max(p.replicas - 1, 1)
    }

    nodeSelector = var.ep_node_selector
  } }
}

resource "helm_release" "ep" {
  for_each = local.processors

  name       = "ep-${each.key}"
  namespace  = kubernetes_namespace_v1.ep[0].metadata[0].name
  repository = "https://splunk.github.io/edge-processor-helm-charts"
  chart      = "edge-processor"
  version    = var.ep_chart_version

  # See the header: readiness can legitimately take 30 minutes.
  wait    = false
  timeout = 600

  values = [yamlencode(local.ep_values[each.key])]

  set_sensitive = [{
    name  = "config.TOKEN"
    value = data.aws_secretsmanager_secret_version.token[each.key].secret_string
  }]
}

# Our own LoadBalancer Service rather than the chart's: the chart's Service is
# ClusterIP by default and cannot set loadBalancerClass. The class is what hands
# it to the AWS Load Balancer Controller (the sok layer runs it with the Service
# mutator webhook off, so nothing would default it), which builds an NLB with IP
# targets and a security group enforcing loadBalancerSourceRanges.
resource "kubernetes_service_v1" "nlb" {
  for_each = local.nlbs

  metadata {
    name      = "ep-${each.key}-nlb"
    namespace = kubernetes_namespace_v1.ep[0].metadata[0].name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-scheme"                        = var.ep_nlb_internet_facing ? "internet-facing" : "internal"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"               = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-subnets"                       = join(",", data.aws_subnets.nlb[0].ids)
      "service.beta.kubernetes.io/aws-load-balancer-attributes"                    = "load_balancing.cross_zone.enabled=true"
      "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes"       = "preserve_client_ip.enabled=${var.ep_nlb_preserve_client_ip}"
      "service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags"      = "Project=splunk,Service=edge-processor,Environment=${var.environment},ManagedBy=terraform"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol"          = "TCP"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"              = tostring(local.probe_port)
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval"          = "10"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold" = "2"
    }
  }

  spec {
    type                        = "LoadBalancer"
    load_balancer_class         = "service.k8s.aws/nlb"
    load_balancer_source_ranges = local.nlb_allowed_cidrs

    # The chart's selector labels for this release.
    selector = {
      "app.kubernetes.io/name"     = "edge-processor"
      "app.kubernetes.io/instance" = "ep-${each.key}"
    }

    dynamic "port" {
      for_each = local.receivers
      content {
        name        = port.value.name
        port        = port.value.port
        target_port = port.value.port
        protocol    = port.value.protocol
      }
    }
  }

  wait_for_load_balancer = true

  depends_on = [helm_release.ep]
}

data "aws_route53_zone" "ep" {
  count        = length(local.hostnames) > 0 ? 1 : 0
  name         = "${local.dns_zone}."
  private_zone = false
}

resource "aws_route53_record" "ep" {
  for_each = local.hostnames

  zone_id = data.aws_route53_zone.ep[0].zone_id
  name    = each.value
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_service_v1.nlb[each.key].status[0].load_balancer[0].ingress[0].hostname]
}

# The same egress isolation the sok layer gives the splunk namespace (SEC-5),
# so instances inside a shared VPC cannot reach arbitrary internal hosts.
# Ingress stays default-allow: NLB IP targets, kubelet probes.
resource "kubernetes_network_policy_v1" "ep_egress" {
  count = local.enabled && var.sok_network_policies_enabled ? 1 : 0

  metadata {
    name      = "ep-egress-isolation"
    namespace = kubernetes_namespace_v1.ep[0].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress { # this namespace and the Splunk pods (in-cluster indexers, HEC)
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.namespace }
        }
      }
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.sok_namespace }
        }
      }
    }

    egress { # Services by ClusterIP, including the API server for the principal Job
      to {
        ip_block {
          cidr = data.aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
        }
      }
    }

    egress { # DNS
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    egress { # HTTPS: a Splunk Cloud control plane, AWS APIs, the EKS API ENIs
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    dynamic "egress" { # a Splunk Enterprise control plane, off-cluster destinations
      for_each = length(var.ep_egress_cidrs) > 0 ? [1] : []
      content {
        dynamic "to" {
          for_each = var.ep_egress_cidrs
          content {
            ip_block {
              cidr = to.value
            }
          }
        }
      }
    }
  }
}
