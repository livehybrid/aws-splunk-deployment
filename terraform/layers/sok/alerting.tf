###############################################################################
# OPS-4 (option a): in-cluster alert watchdog — a 10-min CronJob that posts to
# Slack when something is wrong BETWEEN workflow runs (the START/STOP/CHECKS
# alerts only cover lifecycle moments): CRs not Ready, crash-looping pods, or
# failed Jobs (e.g. the KV backup). Deployed only when the webhook secret id is
# set (var.sok_alert_webhook_secret_id); reuses the kvbackup pattern — its own
# ServiceAccount with read-only RBAC, digest-pinned alpine/k8s image. The
# webhook is read from Secrets Manager at RUN time via IRSA (never in state).
# The richer Splunk-native alert suite arrives with the SOK console app (#53).
###############################################################################

locals {
  watchdog_enabled = var.sok_alert_webhook_secret_id != ""
}

data "aws_iam_policy_document" "watchdog_trust" {
  count = local.watchdog_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.eks.outputs.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${data.terraform_remote_state.eks.outputs.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.namespace}:splunk-watchdog"]
    }
    condition {
      test     = "StringEquals"
      variable = "${data.terraform_remote_state.eks.outputs.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_secretsmanager_secret" "watchdog_webhook" {
  count = local.watchdog_enabled ? 1 : 0
  name  = var.sok_alert_webhook_secret_id
}

data "aws_iam_policy_document" "watchdog" {
  count = local.watchdog_enabled ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.watchdog_webhook[0].arn]
  }
}

resource "aws_iam_role" "watchdog" {
  count              = local.watchdog_enabled ? 1 : 0
  name               = "splunk-sok-${var.environment}-watchdog"
  assume_role_policy = data.aws_iam_policy_document.watchdog_trust[0].json
}

resource "aws_iam_role_policy" "watchdog" {
  count  = local.watchdog_enabled ? 1 : 0
  name   = "watchdog"
  role   = aws_iam_role.watchdog[0].id
  policy = data.aws_iam_policy_document.watchdog[0].json
}

resource "kubernetes_service_account_v1" "watchdog" {
  count = local.watchdog_enabled ? 1 : 0
  metadata {
    name        = "splunk-watchdog"
    namespace   = local.namespace
    annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.watchdog[0].arn }
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_role_v1" "watchdog" {
  count = local.watchdog_enabled ? 1 : 0
  metadata {
    name      = "splunk-watchdog"
    namespace = local.namespace
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["enterprise.splunk.com"]
    resources  = ["*"]
    verbs      = ["get", "list"]
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_role_binding_v1" "watchdog" {
  count = local.watchdog_enabled ? 1 : 0
  metadata {
    name      = "splunk-watchdog"
    namespace = local.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.watchdog[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.watchdog[0].metadata[0].name
    namespace = local.namespace
  }
}

resource "kubernetes_config_map_v1" "watchdog_script" {
  count = local.watchdog_enabled ? 1 : 0
  metadata {
    name      = "splunk-watchdog-script"
    namespace = local.namespace
  }
  data = {
    "watchdog.sh" = <<-EOT
      #!/usr/bin/env bash
      set -u
      NS="$${SOK_NS:-splunk}"
      PROBLEMS=""
      bad_crs=$(kubectl get clustermanager,indexercluster,searchheadcluster,standalone,licensemanager,monitoringconsole -n "$NS" -o jsonpath='{range .items[?(@.status.phase!="Ready")]}{.kind}/{.metadata.name}={.status.phase} {end}' 2>/dev/null)
      [ -n "$bad_crs" ] && PROBLEMS="$PROBLEMS CRs-not-Ready: $bad_crs |"
      crashers=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$3 ~ /CrashLoopBackOff|Error|ImagePull/ {printf "%s(%s) ", $1, $3}')
      [ -n "$crashers" ] && PROBLEMS="$PROBLEMS pods: $crashers|"
      failed_jobs=$(kubectl get jobs -n "$NS" --no-headers 2>/dev/null | awk '$2 !~ /^([0-9]+)\/\1$/ && $4 ~ /h|d/ {printf "%s ", $1}')
      [ -n "$failed_jobs" ] && PROBLEMS="$PROBLEMS stale-jobs: $failed_jobs|"
      [ -z "$PROBLEMS" ] && { echo "healthy"; exit 0; }
      HOOK=$(aws secretsmanager get-secret-value --secret-id "$WEBHOOK_SECRET_ID" --query SecretString --output text 2>/dev/null)
      [ -z "$HOOK" ] && { echo "no webhook — problems: $PROBLEMS"; exit 1; }
      curl -s -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"text\":\":warning: SOK watchdog ($${ENVIRONMENT}): $PROBLEMS\"}" "$HOOK" >/dev/null
      echo "alerted: $PROBLEMS"
    EOT
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_cron_job_v1" "watchdog" {
  count = local.watchdog_enabled ? 1 : 0
  metadata {
    name      = "splunk-watchdog"
    namespace = local.namespace
  }
  spec {
    schedule                      = "*/10 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 2
    job_template {
      metadata { labels = { app = "splunk-watchdog" } }
      spec {
        backoff_limit = 0
        template {
          metadata { labels = { app = "splunk-watchdog" } }
          spec {
            service_account_name = kubernetes_service_account_v1.watchdog[0].metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "watchdog"
              image   = "alpine/k8s:1.34.1@sha256:ec714df3813b5405292860f8a1c55c5727bf8c33c88992f1e981efad8065547f"
              command = ["bash", "/scripts/watchdog.sh"]
              env {
                name  = "SOK_NS"
                value = local.namespace
              }
              env {
                name  = "ENVIRONMENT"
                value = var.environment
              }
              env {
                name  = "WEBHOOK_SECRET_ID"
                value = var.sok_alert_webhook_secret_id
              }
              env {
                name  = "AWS_REGION"
                value = var.region
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
            }
            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map_v1.watchdog_script[0].metadata[0].name
                default_mode = "0555"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_role_binding_v1.watchdog]
}
