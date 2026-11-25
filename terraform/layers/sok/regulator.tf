###############################################################################
# Regulator (github.com/livehybrid/regulator): a control plane + web UI for
# driving Splunk search load — simulates concurrent users, measures latency
# with coordinated-omission correction, and can gate a CI pipeline on results.
# OFF unless var.sok_enable_regulator.
#
# WHY IT LIVES IN THE SPLUNK NAMESPACE rather than its own:
#   - the existing splunk-egress-isolation NetworkPolicy (networkpolicy.tf,
#     pod_selector {} = every pod) already allows DNS, ClusterIP CIDR (so it
#     reaches Splunk management :8089 and web :8000 by service name) and :443
#     out. A second namespace would need its own policy and cross-namespace rules.
#   - worker Jobs the control plane launches land in the same namespace and
#     inherit the same policy, so they reach Splunk the same way.
#
# WHY IT USES A SERVICEACCOUNT (not EKS exec-auth): same reasoning as Stoker —
# running inside the cluster it drives, the in-cluster token is sufficient.
#
# SECURITY CONTEXT: uid/gid 10012 (the image's useradd). Same PVC shadow
# problem as Stoker (see stoker.tf): fsGroup makes the kubelet chgrp the
# volume so uid 10012 can write it. OnRootMismatch avoids re-chown on every
# restart once correct.
#
# ⚠ NO CPU LIMIT BY DESIGN. A throttled load generator produces artificially
# low send rates and short latency tails — the throttle IS the bottleneck, not
# the Splunk cluster. The memory limit is sufficient; drop the CPU limit only
# if you have a good reason (e.g., a guaranteed-tier node class).
###############################################################################

locals {
  regulator_enabled = var.sok_enable_regulator

  regulator_name   = "regulator"
  regulator_labels = { "app.kubernetes.io/name" = "regulator", "app.kubernetes.io/part-of" = "regulator" }

  # Fernet master key for encrypting target credentials at rest.
  # Same derivation approach as stoker_master_key: deterministic, survives
  # apply without a random provider, domain-separated so it is not the
  # pass4SymmKey itself. base64sha256 produces a valid Fernet key shape;
  # the two replaces convert standard to urlsafe alphabet (Fernet requirement).
  regulator_master_key = replace(replace(base64sha256(
    "regulator-fernet-master-key:${data.aws_secretsmanager_secret_version.pass4symmkey.secret_string}"
  ), "+", "-"), "/", "_")

  # REG_PUBLIC_BASE_URL controls how workers reach the control plane, not just
  # a display string. Same hairpin-NAT risk as stoker's PUBLIC_BASE_URL: must
  # be the in-cluster Service URL unless the ALB allow-list also admits the
  # cluster's NAT egress address.
  regulator_public_base_url = var.sok_regulator_public_base_url != "" ? var.sok_regulator_public_base_url : "http://${local.regulator_name}:8080"

  # The seeded target must point at a search head that EXISTS in this shape.
  # web-ingress.tf already knows how these Services are named, so use the same
  # rule: prefer an SHC, fall back to a standalone SH. Hardcoding the SHC name
  # meant a deployment with only standalone search heads seeded a target
  # pointing at a Service that was never created.
  regulator_seed_target_url = (
    var.sok_regulator_seed_target_url != "" ? var.sok_regulator_seed_target_url :
    length(keys(local.shc_map)) > 0 ?
    "https://splunk-shc-${sort(keys(local.shc_map))[0]}-search-head-service:8089" :
    length(keys(local.sh_map)) > 0 ?
    "https://splunk-sh-${sort(keys(local.sh_map))[0]}-standalone-service:8089" : ""
  )

  # ghcr.io/livehybrid/* → <ecr_registry>/docker-public/livehybrid/* (same
  # pattern as stoker and docker.io images in operator.tf / crs.tf).
  regulator_image                = local.ecr_cache ? "${local.ecr_registry}/docker-public/${trimprefix(var.sok_regulator_image, "ghcr.io/")}" : var.sok_regulator_image
  regulator_worker_image         = local.ecr_cache ? "${local.ecr_registry}/docker-public/${trimprefix(var.sok_regulator_worker_image, "ghcr.io/")}" : var.sok_regulator_worker_image
  regulator_browser_worker_image = local.ecr_cache ? "${local.ecr_registry}/docker-public/${trimprefix(var.sok_regulator_browser_worker_image, "ghcr.io/")}" : var.sok_regulator_browser_worker_image
}

# /data holds the SQLite database and imported scenario YAML files.
# Recreate strategy (below) means two pods never contend for the RWO volume.
resource "kubernetes_persistent_volume_claim_v1" "regulator_data" {
  count = local.regulator_enabled ? 1 : 0

  metadata {
    name      = "regulator-data"
    namespace = local.namespace
    labels    = local.regulator_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = local.storage_class
    resources {
      requests = { storage = var.sok_regulator_storage }
    }
  }

  wait_until_bound = false

  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_secret_v1" "regulator" {
  count = local.regulator_enabled ? 1 : 0

  metadata {
    name      = "regulator-secret"
    namespace = local.namespace
    labels    = local.regulator_labels
  }

  # File mount (REG_MASTER_KEY_FILE), never env — same posture as Stoker.
  # Fatal boot error if REG_MASTER_KEY is empty or malformed.
  data = {
    master_key = local.regulator_master_key
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}

###############################################################################
# RBAC for the K8s fleet driver. Verb set matches what the fleet driver calls.
###############################################################################

resource "kubernetes_service_account_v1" "regulator" {
  count = local.regulator_enabled ? 1 : 0

  metadata {
    name      = "regulator"
    namespace = local.namespace
    labels    = local.regulator_labels
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_role_v1" "regulator" {
  count = local.regulator_enabled ? 1 : 0

  metadata {
    name      = "regulator-fleet"
    namespace = local.namespace
    labels    = local.regulator_labels
  }

  rule { # Indexed Jobs: create/manage per-run worker fleet
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list", "watch", "patch", "delete"]
  }

  rule { # per-run target-credential Secrets
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create", "get", "patch", "delete"]
  }

  rule { # worker pod status, log addressing
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "regulator" {
  count = local.regulator_enabled ? 1 : 0

  metadata {
    name      = "regulator-fleet"
    namespace = local.namespace
    labels    = local.regulator_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = one(kubernetes_role_v1.regulator[*].metadata[0].name)
  }

  subject {
    kind      = "ServiceAccount"
    name      = one(kubernetes_service_account_v1.regulator[*].metadata[0].name)
    namespace = local.namespace
  }
}

###############################################################################
# Control plane. Single replica: SQLite on a RWO PVC cannot have two writers.
# Recreate (not RollingUpdate) so two pods never contend for the volume.
# NO CPU LIMIT: a throttled generator produces invalid benchmarks (see top).
###############################################################################

resource "kubernetes_deployment_v1" "regulator" {
  count = local.regulator_enabled ? 1 : 0

  metadata {
    name      = local.regulator_name
    namespace = local.namespace
    labels    = local.regulator_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.regulator_labels
    }

    template {
      metadata {
        labels = local.regulator_labels
      }

      spec {
        service_account_name = one(kubernetes_service_account_v1.regulator[*].metadata[0].name)

        dynamic "affinity" {
          for_each = var.sok_regulator_node_role != "" ? [var.sok_regulator_node_role] : []
          content {
            node_affinity {
              required_during_scheduling_ignored_during_execution {
                node_selector_term {
                  match_expressions {
                    key      = "splunk-sok/role"
                    operator = "In"
                    values   = [affinity.value]
                  }
                }
              }
            }
          }
        }

        dynamic "toleration" {
          for_each = var.sok_regulator_node_role != "" ? [var.sok_regulator_node_role] : []
          content {
            key      = "splunk-sok/role"
            operator = "Equal"
            value    = toleration.value
            effect   = "NoSchedule"
          }
        }

        # uid 10012 is the image's useradd. A fresh PVC arrives owned root:root,
        # so fsGroup makes the kubelet chgrp to 10012 + g+w, letting the app
        # write the SQLite file. OnRootMismatch skips the walk on subsequent
        # restarts once ownership is already correct.
        security_context {
          run_as_user            = 10012
          run_as_group           = 10012
          run_as_non_root        = true
          fs_group               = 10012
          fs_group_change_policy = "OnRootMismatch"
        }

        termination_grace_period_seconds = 45

        container {
          name  = "regulator"
          image = local.regulator_image

          port {
            name           = "http"
            container_port = 8080
          }

          env {
            name  = "REG_DATABASE_URL"
            value = var.sok_regulator_database_url
          }
          env {
            name  = "REG_MASTER_KEY_FILE"
            value = "/run/secrets/regulator/master_key"
          }
          env {
            name  = "REG_ADMIN_USER"
            value = "admin"
          }
          env {
            name  = "REG_ADMIN_PASSWORD"
            value = "password"
          }
          env {
            name  = "REG_PUBLIC_BASE_URL"
            value = local.regulator_public_base_url
          }
          env {
            name  = "REG_WORKER_IMAGE"
            value = local.regulator_worker_image
          }
          env {
            name  = "REG_BROWSER_WORKER_IMAGE"
            value = local.regulator_browser_worker_image
          }
          env {
            name  = "REG_DEFAULT_FLEET"
            value = "k8s"
          }
          env {
            name  = "REG_K8S_IN_CLUSTER"
            value = "1"
          }
          env {
            name  = "REG_K8S_NAMESPACE"
            value = local.namespace
          }
          # Placement and admission, stated separately and both derived from
          # the node role, so neither depends on the node group happening to
          # label and taint with the same string.
          #
          # eks.tf gives a role group the label splunk-sok/role=<role> AND
          # the taint splunk-sok/role=<role>:NoSchedule. The selector picks
          # the node, the toleration is what lets that reserved node accept the
          # pod. Setting the selector to the convenience label workload=regulator
          # is what left every worker Pending: regulator derived its toleration
          # from the selector, so it tolerated a taint that does not exist.
          #
          # REG_K8S_TOLERATIONS needs a regulator image built after the
          # toleration fix. On an older image it is ignored and the derived
          # fallback produces the same toleration anyway, because the selector
          # key here matches the taint key, so this is safe to deploy first.
          env {
            name  = "REG_K8S_NODE_SELECTOR"
            value = "splunk-sok/role=${var.sok_regulator_node_role}"
          }
          env {
            name  = "REG_K8S_TOLERATIONS"
            value = "splunk-sok/role=${var.sok_regulator_node_role}:NoSchedule"
          }
          env {
            name  = "REG_HEC_URL"
            value = local.internal_hec_url
          }
          # Regulator's OWN telemetry, kept out of the index holding the
          # generated data and out of main: this describes the load generator,
          # not the cluster under test.
          env {
            name  = "REG_HEC_INDEX"
            value = var.sok_regulator_index
          }
          env {
            name  = "REG_HEC_TOKEN"
            value = kubernetes_secret_v1.global.data["hec_token"]
          }
          env {
            name  = "REG_HEC_VERIFY_TLS"
            value = "0"
          }
          env {
            name  = "REG_SEED_TARGET_NAME"
            value = "splunk-local"
          }
          env {
            name  = "REG_SEED_TARGET_URL"
            value = local.regulator_seed_target_url
          }
          env {
            name  = "REG_SEED_TARGET_USERNAME"
            value = "admin"
          }
          env {
            name  = "REG_SEED_TARGET_PASSWORD"
            value = kubernetes_secret_v1.global.data["password"]
          }
          env {
            name  = "REG_SEED_TARGET_VERIFY_TLS"
            value = "0"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "master-key"
            mount_path = "/run/secrets/regulator"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 6
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = { memory = "1Gi" }
            limits   = { memory = "4Gi" }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = one(kubernetes_persistent_volume_claim_v1.regulator_data[*].metadata[0].name)
          }
        }

        volume {
          name = "master-key"
          secret {
            secret_name = one(kubernetes_secret_v1.regulator[*].metadata[0].name)
          }
        }
      }
    }
  }

  depends_on = [kubernetes_role_binding_v1.regulator]
}

# Named "regulator" to match local.web_component_services["regulator"] in
# web-ingress.tf. Port 8080, same as stoker.
resource "kubernetes_service_v1" "regulator" {
  count = local.regulator_enabled ? 1 : 0

  metadata {
    name      = local.regulator_name
    namespace = local.namespace
    labels    = local.regulator_labels
  }

  spec {
    selector = local.regulator_labels
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = 8080
      target_port = "http"
    }
  }
}

# Fails the plan rather than producing an Ingress rule pointing at a Service
# that was never created.
resource "terraform_data" "regulator_guard" {
  input = local.regulator_enabled

  lifecycle {
    precondition {
      condition     = local.regulator_enabled || !contains(var.sok_web_external_components, "regulator")
      error_message = "sok_web_external_components includes \"regulator\" but sok_enable_regulator is false, so no regulator Service exists to route to. Set sok_enable_regulator = true, or drop \"regulator\" from the component list."
    }
  }
}
