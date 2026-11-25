###############################################################################
# KV-store backup, an in-cluster CronJob backs up the SHC KV store to the
# persistent kvbackup bucket (account layer) every 6h via IRSA. Enabled when
# any SHC exists (length(local.shc_map) > 0); standalone SH KV stores are
# disposable (nightly destroy). Restore is manual / start-workflow via
# scripts/sok-kvstore-restore.sh.
#
# The CronJob pod (kubectl+aws image) uses its own ServiceAccount:
#   - RBAC: pods/exec (kubectl exec + cp into the SHC member),
#   - IRSA: S3 read/write on the kvbackup bucket + kms on the workspace key.
# The backup itself runs `splunk backup kvstore` INSIDE the SHC member (password
# read in-pod), see scripts/sok-kvstore-backup.sh, mounted here so the CronJob
# and manual `make sok-kvstore-backup` share one implementation.
#
# Validated end-to-end against a live dev SHC 2026-07-10 (backup -> S3 SSE-KMS ->
# restore into the KV store captain). SHC-only by design; dev's Standalone KV
# store is disposable (nightly destroy), so having no dev backup is intentional.
###############################################################################

data "aws_s3_bucket" "kvbackup" {
  count  = length(local.shc_map) > 0 ? 1 : 0
  bucket = "${local.bucket_root}-splunk-kvbackup-${local.environment}"
}

data "aws_iam_policy_document" "kvbackup_trust" {
  count = length(local.shc_map) > 0 ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.namespace}:splunk-kvbackup"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "kvbackup" {
  count = length(local.shc_map) > 0 ? 1 : 0
  statement {
    sid       = "KvbackupList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [data.aws_s3_bucket.kvbackup[0].arn]
  }
  statement {
    sid       = "KvbackupObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${data.aws_s3_bucket.kvbackup[0].arn}/*"]
  }
  statement {
    sid       = "KvbackupKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [data.aws_kms_alias.smartstore.target_key_arn]
  }
}

resource "aws_iam_role" "kvbackup" {
  count              = length(local.shc_map) > 0 ? 1 : 0
  name               = "splunk-sok-${local.environment}-kvbackup"
  assume_role_policy = data.aws_iam_policy_document.kvbackup_trust[0].json
}

resource "aws_iam_role_policy" "kvbackup" {
  count  = length(local.shc_map) > 0 ? 1 : 0
  name   = "kvbackup"
  role   = aws_iam_role.kvbackup[0].id
  policy = data.aws_iam_policy_document.kvbackup[0].json
}

resource "kubernetes_service_account_v1" "kvbackup" {
  count = length(local.shc_map) > 0 ? 1 : 0
  metadata {
    name        = "splunk-kvbackup"
    namespace   = local.namespace
    annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.kvbackup[0].arn }
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

# RBAC: exec into the SH pods (kubectl exec and kubectl cp both use pods/exec).
resource "kubernetes_role_v1" "kvbackup" {
  count = length(local.shc_map) > 0 ? 1 : 0
  metadata {
    name      = "splunk-kvbackup"
    namespace = local.namespace
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_role_binding_v1" "kvbackup" {
  count = length(local.shc_map) > 0 ? 1 : 0
  metadata {
    name      = "splunk-kvbackup"
    namespace = local.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.kvbackup[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kvbackup[0].metadata[0].name
    namespace = local.namespace
  }
}


# Mount scripts/sok-kvstore-backup.sh so the CronJob and manual runs share it.
resource "kubernetes_config_map_v1" "kvbackup_script" {
  count = length(local.shc_map) > 0 ? 1 : 0
  metadata {
    name      = "splunk-kvbackup-script"
    namespace = local.namespace
  }
  data = {
    "sok-kvstore-backup.sh" = file("${path.module}/../../../scripts/sok-kvstore-backup.sh")
  }
  depends_on = [kubernetes_namespace_v1.splunk]
}

resource "kubernetes_cron_job_v1" "kvbackup" {
  count = length(local.shc_map) > 0 ? 1 : 0
  metadata {
    name      = "splunk-kvbackup"
    namespace = local.namespace
  }
  spec {
    schedule                      = "13 * * * *" # every 6h
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata { labels = { app = "splunk-kvbackup" } }
      spec {
        backoff_limit = 1
        template {
          metadata { labels = { app = "splunk-kvbackup" } }
          spec {
            service_account_name = kubernetes_service_account_v1.kvbackup[0].metadata[0].name
            restart_policy       = "Never"
            container {
              name = "kvbackup"
              # kubectl + aws + bash. Community image, hence DIGEST-pinned
              # (SEC-6/DEP-8), the tag documents the version, the digest is
              # what runs; a mutated tag can't ride into the 6-hourly job. A
              # first-party replacement (own ECR build) stays open under #38.
              image   = "${local.ecr_registry}/docker-public/alpine/k8s:1.34.1"
              command = ["bash", "/scripts/sok-kvstore-backup.sh", local.environment]
              env {
                name  = "AWS_REGION"
                value = var.region
              }
              env {
                name  = "SOK_NS"
                value = local.namespace
              }
              # Pass the bucket the IAM policy above actually grants on. Both
              # scripts previously hardcoded a stale pre-fork "livehybrid-..."
              # name, so the upload aimed at a bucket this role has no policy for
              # — an AccessDenied at the very last step, after the backup had
              # already run. Sourcing it from the same data source that builds
              # the policy means the two cannot drift again.
              env {
                name  = "KVBACKUP_BUCKET"
                value = data.aws_s3_bucket.kvbackup[0].bucket
              }
              # The bucket policy Denies PutObject unless the request carries
              # x-amz-server-side-encryption=aws:kms AND the matching key ARN, and
              # StringNotEquals is TRUE when those keys are absent — so a plain
              # `aws s3 cp` is refused. The script sends them explicitly; this is
              # the ARN it must send, and it is the SAME value the IAM policy
              # above grants kms:GenerateDataKey on.
              env {
                name  = "KVBACKUP_KMS_ARN"
                value = data.aws_kms_alias.smartstore.target_key_arn
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
                name         = kubernetes_config_map_v1.kvbackup_script[0].metadata[0].name
                default_mode = "0555"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_service_account_v1.kvbackup, kubernetes_role_binding_v1.kvbackup]
}