###############################################################################
# Stoker (github.com/livehybrid/stoker): a control plane + web UI for driving
# fleets of Splunk HEC data generators. OFF unless var.sok_enable_stoker.
#
# WHY IT LIVES IN THE SPLUNK NAMESPACE rather than its own:
#   - the existing splunk-egress-isolation NetworkPolicy (networkpolicy.tf,
#     pod_selector {} = every pod) already allows exactly what Stoker needs:
#     DNS, the ClusterIP service CIDR (so it reaches Splunk HEC by service name)
#     and :443 out (git pack sync, the EKS API). A second namespace would need
#     its own policy plus a cross-namespace rule to reach HEC.
#   - the worker Jobs the control plane launches land in the same namespace and
#     inherit the same policy, so they can reach HEC the same way.
#
# WHY IT AUTHENTICATES AS A ServiceAccount, not via EKS exec-auth: upstream runs
# the control plane on-prem and reaches EKS with an eks:DescribeCluster IAM
# principal mapped into the RBAC group "stoker:control-plane". Running INSIDE the
# cluster it drives, the in-cluster ServiceAccount token is enough, which is the
# second subject upstream's own infra/k8s/rbac.yaml already binds.
#
# ⚠ ONE MANUAL STEP PER BUILD. Stoker resolves the execution driver from a row in
# its `fleets` table. seed_fleets() (server/lifecycle.py) creates only fake-local
# (in-process, generates nothing) and swarm-local (needs Portainer), and there is
# NO /api/fleets endpoint, so a k8s fleet cannot be created through the API. With
# the default SQLite backend the file lives on this pod's RWO volume, so nothing
# external can write it either. Create it once after the stack is up:
#
#   kubectl -n <ns> exec deploy/stoker -- python -c "
#   from server.db import SessionLocal; from server.models import Fleet
#   d=SessionLocal()
#   if not d.query(Fleet).filter_by(name='k8s-local').first():
#       d.add(Fleet(name='k8s-local', driver='k8s',
#                   config_json={'namespace': '<ns>'})); d.commit()
#   print('ok')"
#
# then set a spec's fleet to k8s-local. Verify the exact SessionLocal/Fleet
# import against the image before relying on it: this is written from the repo,
# not run. Automating it is the natural follow-up (it wants Postgres, so a seed
# Job can reach the DB over the network).
###############################################################################

locals {
  stoker_enabled = var.sok_enable_stoker

  stoker_name   = "stoker"
  stoker_labels = { "app.kubernetes.io/name" = "stoker", "app.kubernetes.io/part-of" = "stoker" }

  # Fernet master key for encrypting HEC tokens at rest, plus the derived
  # per-run JWT secret (server/crypto.py keys both off it).
  #
  # DERIVED, not random, and not auto-generated. Stoker WILL generate one when
  # STOKER_MASTER_KEY is unset (config.py _generate_master_key) but calls it a
  # throwaway for local dev: it would change on every pod restart, and every HEC
  # token already encrypted in the database would become undecryptable. It has
  # to be stable for the life of the data.
  #
  # base64sha256 gives base64 of a 32-byte digest, which is exactly a Fernet
  # key's shape; the two replaces convert the standard alphabet to urlsafe,
  # which is what Fernet requires. Domain-separated by the prefix so it is not
  # the pass4SymmKey itself. Deterministic, so it survives an apply without a
  # random provider (none is in this layer's lock file) and without asking for
  # another Secrets Manager entry.
  stoker_master_key = replace(replace(base64sha256(
    "stoker-fernet-master-key:${data.aws_secretsmanager_secret_version.pass4symmkey.secret_string}"
  ), "+", "-"), "/", "_")

  # PUBLIC_BASE_URL is NOT just cosmetic: docs/WORKER-CONTRACT.md states the
  # control plane projects STOKER_CONTROL_URL = PUBLIC_BASE_URL into every worker
  # pod, and the agent talks to {CONTROL_URL}/api/agent/runs/... for claim,
  # heartbeat and final.
  #
  # So it MUST be the in-cluster Service URL, not the ALB hostname. Pointing it
  # at the ALB makes every worker hairpin out through NAT to an internet-facing
  # load balancer whose allow-list (sok_web_external_allowed_cidrs) does not
  # contain the cluster's egress IP: the agents never claim, and runs sit in
  # provisioning with nothing in the control-plane log to explain it.
  #
  # ⚠ COST: absolute links the UI builds from this (webhook URLs, anything
  # externally shared) will show http://stoker:8080, which no browser outside the
  # cluster resolves. Worker connectivity beats link cosmetics. Override with
  # sok_stoker_public_base_url ONLY if the ALB allow-list also admits the
  # cluster's NAT egress address.
  stoker_public_base_url = var.sok_stoker_public_base_url != "" ? var.sok_stoker_public_base_url : "http://${local.stoker_name}:8080"

  # ghcr.io/livehybrid/* → <ecr_registry>/docker-public/livehybrid/* (same
  # pattern as docker.io images in operator.tf / crs.tf). The variable default
  # stays the canonical public address so it is human-readable; the rewrite
  # happens here so no tfvars need to know about ECR paths.
  stoker_image        = local.ecr_cache ? "${local.ecr_registry}/docker-public/${trimprefix(var.sok_stoker_image, "ghcr.io/")}" : var.sok_stoker_image
  stoker_worker_image = local.ecr_cache ? "${local.ecr_registry}/docker-public/${trimprefix(var.sok_stoker_worker_image, "ghcr.io/")}" : var.sok_stoker_worker_image
}

# /data holds the SQLite file, content-addressed bundle tarballs and git clones.
# ONE volume for all three because the default backend puts the database there
# too, and a second claim would only add another thing to reclaim on teardown.
# reclaimPolicy on these StorageClasses is Delete, so the nightly stop takes it.
resource "kubernetes_persistent_volume_claim_v1" "stoker_data" {
  count = local.stoker_enabled ? 1 : 0

  metadata {
    name      = "stoker-data"
    namespace = local.namespace
    labels    = local.stoker_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = local.storage_class
    resources {
      requests = { storage = var.sok_stoker_storage }
    }
  }

  wait_until_bound = false

  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_secret_v1" "stoker" {
  count = local.stoker_enabled ? 1 : 0

  metadata {
    name      = "stoker-secret"
    namespace = local.namespace
    labels    = local.stoker_labels
  }

  # File mount, never env: upstream's own posture (stack.yml uses a swarm secret
  # with STOKER_MASTER_KEY_FILE for exactly this reason).
  data = {
    master_key = local.stoker_master_key
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}

###############################################################################
# RBAC for the K8sDriver, transcribed from upstream infra/k8s/rbac.yaml.
# Namespaced to THIS layer's namespace rather than the hardcoded "stoker", and
# bound only to the ServiceAccount (the "stoker:control-plane" Group subject is
# for the off-cluster EKS exec-auth path, which does not apply here).
#
# The verb set is exactly what server/drivers/k8s.py calls. Keep it that way.
###############################################################################

resource "kubernetes_service_account_v1" "stoker" {
  count = local.stoker_enabled ? 1 : 0

  metadata {
    name      = "stoker-driver"
    namespace = local.namespace
    labels    = local.stoker_labels
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_role_v1" "stoker" {
  count = local.stoker_enabled ? 1 : 0

  metadata {
    name      = "stoker-driver"
    namespace = local.namespace
    labels    = local.stoker_labels
  }

  rule { # Indexed Jobs: the per-run workload (create/read/scale/stop/reconcile)
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list", "watch", "patch", "delete"]
  }

  rule { # per-run HEC-token Secrets, patched with the Job ownerReference
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create", "get", "list", "watch", "patch", "delete"]
  }

  rule { # worker pods: status view and log addressing. The Job controller
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule { # the logs() live tail
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "stoker" {
  count = local.stoker_enabled ? 1 : 0

  metadata {
    name      = "stoker-driver"
    namespace = local.namespace
    labels    = local.stoker_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = one(kubernetes_role_v1.stoker[*].metadata[0].name)
  }

  subject {
    kind      = "ServiceAccount"
    name      = one(kubernetes_service_account_v1.stoker[*].metadata[0].name)
    namespace = local.namespace
  }
}

###############################################################################
# The control plane. Single replica by design: it owns the SQLite file and the
# bundle/repo directories on one RWO volume, and upstream's own stack runs
# replicas: 1. Recreate (not RollingUpdate) so two pods never contend for the
# volume during a rollout.
###############################################################################

resource "kubernetes_deployment_v1" "stoker" {
  count = local.stoker_enabled ? 1 : 0

  metadata {
    name      = local.stoker_name
    namespace = local.namespace
    labels    = local.stoker_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.stoker_labels
    }

    template {
      metadata {
        labels = local.stoker_labels
      }

      spec {
        service_account_name = one(kubernetes_service_account_v1.stoker[*].metadata[0].name)

        dynamic "affinity" {
          for_each = var.sok_stoker_node_role != "" ? [var.sok_stoker_node_role] : []
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
          for_each = var.sok_stoker_node_role != "" ? [var.sok_stoker_node_role] : []
          content {
            key      = "splunk-sok/role"
            operator = "Equal"
            value    = toleration.value
            effect   = "NoSchedule"
          }
        }

        # REQUIRED, not hygiene. The image does:
        #   useradd --uid 10002 stoker
        #   mkdir -p /data/bundles /data/repos && chown -R stoker:stoker /data
        #   USER stoker
        # but that chown is baked into an image LAYER, and mounting a PVC at
        # /data SHADOWS it. The fresh volume arrives owned root:root mode 0755,
        # so uid 10002 cannot create the SQLite file and the pod crash-loops on:
        #   sqlite3.OperationalError: unable to open database file
        # fsGroup makes the kubelet chgrp the volume to 10002 and add g+w, which
        # is what lets the app write. The /data/bundles and /data/repos the image
        # created are shadowed too, but the app recreates them itself
        # (os.makedirs(..., exist_ok=True) in bundles.py and gitsync/sync.py), so
        # no initContainer is needed.
        #
        # OnRootMismatch so the kubelet does not walk and re-chown the whole
        # volume on every restart once it is already correct.
        #
        # ⚠ 10002 is the image's uid. If upstream changes the useradd, change it
        # here too, or the pod loses write access to its own volume again.
        security_context {
          run_as_user            = 10002
          run_as_group           = 10002
          fs_group               = 10002
          fs_group_change_policy = "OnRootMismatch"
        }

        # 45s matches upstream's stop_grace_period: the control plane drains
        # in-flight runs on SIGTERM.
        termination_grace_period_seconds = 45

        container {
          name  = "stoker"
          image = local.stoker_image

          port {
            name           = "http"
            container_port = 8080
          }

          env {
            name  = "DATABASE_URL"
            value = var.sok_stoker_database_url
          }
          env {
            name  = "STOKER_MASTER_KEY_FILE"
            value = "/run/secrets/stoker/master_key"
          }
          env {
            name  = "PUBLIC_BASE_URL"
            value = local.stoker_public_base_url
          }
          env {
            name  = "WORKER_IMAGE"
            value = local.stoker_worker_image
          }
          env {
            name  = "BUNDLE_DIR"
            value = "/data/bundles"
          }
          env {
            name  = "REPO_CLONE_DIR"
            value = "/data/repos"
          }
          env {
            name  = "K8S_NAMESPACE"
            value = "splunk"
          }
          env {
            name  = "K8S_NODE_SELECTOR"
            value = "workload=stoker"
          }
          # Stoker's generated events go wherever the RUN's target says, and a
          # target is a runtime object rather than Terraform state, so the index
          # is set when the target is created (see the bootstrap scripts, which
          # default to var.sok_stoker_index). Surfaced here so the intended
          # index is visible to anything reading the deployment, and so a
          # future target-seeding env has one obvious place to read it from.
          env {
            name  = "STOKER_DEFAULT_INDEX_HINT"
            value = var.sok_stoker_index
          }
          env {
            name = "STOKER_MAX_EPS_PER_WORKER"
            # High number to give us control
            value = "1000000"
          }
          env {
            name = "STOKER_MAX_GB_DAY_PER_WORKER"
            # High number - 10TB
            value = "100000"
          }
          env {
            name  = "STOKER_ADMIN_USER"
            value = "admin"
          }
          env {
            name  = "STOKER_ADMIN_PASSWORD"
            value = "password"
          }
          env {
            name  = "DOGFOOD_HEC_URL"
            value = local.internal_hec_url
          }
          env {
            name  = "DOGFOOD_HEC_TOKEN"
            value = kubernetes_secret_v1.global.data["hec_token"]
          }
          env {
            name  = "K8S_TOLERATIONS"
            value = "splunk-sok/role=stoker:NoSchedule"
          }

          # Worker-pod resource requests for the seeded k8s-local fleet. With
          # none of these set, worker Jobs carry NO resources block at all, the
          # scheduler has no signal, and a large fleet packs unpredictably --
          # per-worker throughput then varies with whatever else lands on the
          # node. eventgen is one GIL-bound core, so the CPU REQUEST is the
          # knob that matters; a limit would cap throughput instead of
          # reserving a share. Empty (the default) preserves the previous
          # no-resources behaviour exactly.
          #
          # NB: seed_fleets() writes the fleet row only on FIRST boot
          # (`if "k8s-local" not in existing`). On a deployment whose /data PVC
          # already holds a k8s-local row, changing these has no effect until
          # the fleet's stored config_json is updated.
          dynamic "env" {
            for_each = {
              for k, v in {
                K8S_WORKER_CPU_REQUEST    = var.sok_stoker_worker_cpu_request
                K8S_WORKER_MEMORY_REQUEST = var.sok_stoker_worker_memory_request
                K8S_WORKER_CPU_LIMIT      = var.sok_stoker_worker_cpu_limit
                K8S_WORKER_MEMORY_LIMIT   = var.sok_stoker_worker_memory_limit
              } : k => v if v != ""
            }
            content {
              name  = env.key
              value = env.value
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "master-key"
            mount_path = "/run/secrets/stoker"
            read_only  = true
          }

          # /healthz is public (server/app.py registers it ahead of the auth
          # middleware), so probes need no credential.
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
            requests = { cpu = "100m", memory = "512Mi" }
            limits   = { memory = "2Gi" }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = one(kubernetes_persistent_volume_claim_v1.stoker_data[*].metadata[0].name)
          }
        }

        volume {
          name = "master-key"
          secret {
            secret_name = one(kubernetes_secret_v1.stoker[*].metadata[0].name)
          }
        }
      }
    }
  }

  depends_on = [kubernetes_role_binding_v1.stoker]
}

# Named "stoker" to match local.web_component_services["stoker"] in
# web-ingress.tf. Port 8080, which is why the ingress needed per-component
# ports: every Splunk UI is 8000 and this one is not.
resource "kubernetes_service_v1" "stoker" {
  count = local.stoker_enabled ? 1 : 0

  metadata {
    name      = local.stoker_name
    namespace = local.namespace
    labels    = local.stoker_labels
  }

  spec {
    selector = local.stoker_labels
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
resource "terraform_data" "stoker_guard" {
  input = local.stoker_enabled

  lifecycle {
    precondition {
      condition     = local.stoker_enabled || !contains(var.sok_web_external_components, "stoker")
      error_message = "sok_web_external_components includes \"stoker\" but sok_enable_stoker is false, so no stoker Service exists to route to. Set sok_enable_stoker = true, or drop \"stoker\" from the component list."
    }
  }
}