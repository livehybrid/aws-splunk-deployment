###############################################################################
# NodeLocal DNSCache — a per-node DNS cache (DaemonSet) that intercepts pod DNS
# queries locally and forwards to CoreDNS over TCP.
#
# Why: on the multisite bring-up, indexers crash-looped with a SmartStore FATAL
# ("S3ClientProps did not find credentials") because sts.<region> DNS resolution
# intermittently FAILS — the classic EKS UDP-conntrack race on the pod->CoreDNS
# ->VPC-resolver path. IRSA is configured correctly; it's the DNS blip the plan
# (K7.1) warned would "wedge the CM". node-local-dns removes the pod->CoreDNS
# UDP+DNAT hop (local cache) and uses force_tcp to the upstream, killing the race.
#
# Transparent mode (no kubelet change): the node-cache binds a dummy interface
# to BOTH the link-local 169.254.20.10 AND the kube-dns ClusterIP and sets NOTRACK
# rules, so pods keep using the kube-dns IP from their resolv.conf and are
# intercepted locally. Faithful port of the upstream nodelocaldns.yaml
# (registry.k8s.io/dns/k8s-dns-node-cache), built as typed resources because this
# layer has no kubectl provider.
###############################################################################

locals {
  nodelocaldns_ip    = "169.254.20.10"
  nodelocaldns_image = "registry.k8s.io/dns/k8s-dns-node-cache:1.26.8"
  # kube-dns Service ClusterIP = .10 of the EKS service CIDR (default
  # 10.100.0.0/16). __PILLAR__CLUSTER__DNS__ / __PILLAR__UPSTREAM__SERVERS__ stay
  # literal — the node-cache binary fills them at runtime from -upstreamsvc and
  # the node's /etc/resolv.conf.
  nodelocaldns_corefile = <<-EOT
    cluster.local:53 {
        errors
        cache {
                success 9984 30
                denial 9984 5
        }
        reload
        loop
        bind ${local.nodelocaldns_ip} ${var.eks_cluster_dns_ip}
        forward . __PILLAR__CLUSTER__DNS__ {
                force_tcp
        }
        prometheus :9253
        health ${local.nodelocaldns_ip}:8080
        }
    in-addr.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind ${local.nodelocaldns_ip} ${var.eks_cluster_dns_ip}
        forward . __PILLAR__CLUSTER__DNS__ {
                force_tcp
        }
        prometheus :9253
        }
    ip6.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind ${local.nodelocaldns_ip} ${var.eks_cluster_dns_ip}
        forward . __PILLAR__CLUSTER__DNS__ {
                force_tcp
        }
        prometheus :9253
        }
    .:53 {
        errors
        cache 30
        reload
        loop
        bind ${local.nodelocaldns_ip} ${var.eks_cluster_dns_ip}
        forward . __PILLAR__UPSTREAM__SERVERS__
        prometheus :9253
        }
  EOT
}

resource "kubernetes_service_account_v1" "node_local_dns" {
  metadata {
    name      = "node-local-dns"
    namespace = "kube-system"
    labels    = { "kubernetes.io/cluster-service" = "true" }
  }
  depends_on = [module.eks]
}

# Stable upstream for cluster.local queries — selects the CoreDNS pods.
resource "kubernetes_service_v1" "kube_dns_upstream" {
  metadata {
    name      = "kube-dns-upstream"
    namespace = "kube-system"
    labels    = { "k8s-app" = "kube-dns", "kubernetes.io/name" = "KubeDNSUpstream" }
  }
  spec {
    selector = { "k8s-app" = "kube-dns" }
    port {
      name        = "dns"
      port        = 53
      protocol    = "UDP"
      target_port = 53
    }
    port {
      name        = "dns-tcp"
      port        = 53
      protocol    = "TCP"
      target_port = 53
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_config_map_v1" "node_local_dns" {
  metadata {
    name      = "node-local-dns"
    namespace = "kube-system"
  }
  data = { "Corefile" = local.nodelocaldns_corefile }

  depends_on = [module.eks]
}

resource "kubernetes_daemon_set_v1" "node_local_dns" {
  metadata {
    name      = "node-local-dns"
    namespace = "kube-system"
    labels    = { "k8s-app" = "node-local-dns" }
  }
  spec {
    strategy {
      type = "RollingUpdate"
      rolling_update { max_unavailable = "10%" }
    }
    selector {
      match_labels = { "k8s-app" = "node-local-dns" }
    }
    template {
      metadata {
        labels = { "k8s-app" = "node-local-dns" }
      }
      spec {
        priority_class_name  = "system-node-critical"
        service_account_name = kubernetes_service_account_v1.node_local_dns.metadata[0].name
        host_network         = true
        dns_policy           = "Default" # don't use cluster DNS

        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
        toleration {
          effect   = "NoExecute"
          operator = "Exists"
        }
        toleration {
          effect   = "NoSchedule"
          operator = "Exists"
        }

        container {
          name  = "node-cache"
          image = local.nodelocaldns_image
          args = [
            "-localip", "${local.nodelocaldns_ip},${var.eks_cluster_dns_ip}",
            "-conf", "/etc/Corefile",
            "-upstreamsvc", "kube-dns-upstream",
          ]
          resources {
            requests = { cpu = "25m", memory = "5Mi" }
          }
          security_context {
            capabilities { add = ["NET_ADMIN"] }
          }
          port {
            container_port = 53
            name           = "dns"
            protocol       = "UDP"
          }
          port {
            container_port = 53
            name           = "dns-tcp"
            protocol       = "TCP"
          }
          port {
            container_port = 9253
            name           = "metrics"
            protocol       = "TCP"
          }
          liveness_probe {
            http_get {
              host = local.nodelocaldns_ip
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 60
            timeout_seconds       = 5
          }
          volume_mount {
            name       = "xtables-lock"
            mount_path = "/run/xtables.lock"
          }
          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/coredns"
          }
          volume_mount {
            name       = "kube-dns-config"
            mount_path = "/etc/kube-dns"
          }
        }

        volume {
          name = "xtables-lock"
          host_path {
            path = "/run/xtables.lock"
            type = "FileOrCreate"
          }
        }
        volume {
          name = "kube-dns-config"
          config_map {
            name     = "kube-dns"
            optional = true
          }
        }
        volume {
          name = "config-volume"
          config_map {
            name = kubernetes_config_map_v1.node_local_dns.metadata[0].name
            items {
              key  = "Corefile"
              path = "Corefile.base"
            }
          }
        }
      }
    }
  }

  depends_on = [module.eks]
}
