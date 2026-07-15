###############################################################################
# SEC-5: egress isolation for the splunk namespace. Dev SOK pods live INSIDE
# the prod VPC, without policies they can reach the prod EC2 estate's
# LM:8089 / HF:9997 / mgmt ports. This egress-only policy allowlists what
# Splunk actually needs and cuts everything else VPC-internal:
#   - anything within the namespace (clustering, bundles, dist search, exec),
#   - DNS :53 anywhere (coredns svc + node-local cache),
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

    egress { # intra-namespace: replication, bundles, dist search, kubectl exec targets
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.namespace }
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
