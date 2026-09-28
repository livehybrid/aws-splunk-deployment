###############################################################################
# SEC-5: egress isolation for the splunk namespace. Dev SOK pods live INSIDE
# the prod VPC, without policies they can reach the prod EC2 estate's
# LM:8089 / HF:9997 / mgmt ports. This egress-only policy allowlists what
# Splunk actually needs and cuts everything else VPC-internal:
#   - intra-namespace pod IPs (clustering, bundles, dist search, exec),
#   - ClusterIP service CIDR (172.20.0.0/16): pods connect to Services by
#     ClusterIP, not pod IP, so the namespaceSelector alone is insufficient —
#     kube-proxy/eBPF rewrites the ClusterIP to a pod IP AFTER the network
#     policy decision, so the policy must explicitly allow the service CIDR.
#   - DNS :53 anywhere (coredns service + node-local cache),
#   - TCP :443 anywhere (S3/STS/KMS via public or VPC endpoints, EKS API ENIs).
# Prod-internal Splunk ports (8089/9997/8000/8088 on EC2 instances) match no
# rule -> dropped. Ingress is left default-allow (ALB ip-targets, kubelet
# probes, operator). ENFORCEMENT requires the vpc-cni network-policy agent
# (enableNetworkPolicy in the eks layer), without it this object is inert.
###############################################################################

resource "kubernetes_network_policy_v1" "splunk_egress" {
  count = var.sok_network_policies_enabled ? 1 : 0

  metadata {
    name      = "splunk-egress-isolation"
    namespace = local.namespace
  }

  spec {
    pod_selector {} # every pod in the namespace
    policy_types = ["Egress"]

    egress { # intra-namespace pod IPs: replication, bundles, dist search, exec
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.namespace }
        }
      }
    }

    egress { # ClusterIP service CIDR — pods reach Services by VIP, not pod IP
      to {
        ip_block {
          cidr = "172.20.0.0/16"
        }
      }
    }

    egress { # DNS (coredns service + node-local cache)
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    egress { # HTTPS: S3/STS/KMS/splunkd->AWS + the EKS API server ENIs
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}
