###############################################################################
# Splunk AI tier on the SOK cluster. See docs/ai-tier.md.
#
# What runs where:
#   GPU nodes (eks_node_groups[*].gpu)  Ray GPU workers serving the models
#   general nodes                       Ray head, Weaviate, SAIA API, SLIM, the
#                                       AI operator, KubeRay
#   SOK search head (sh-<ai_search_head>) issues the JWTs SAIA and SLIM trust
#   S3 (account layer)                  model weights and AI artifacts
###############################################################################

###############################################################################
# Guards: fail at plan time on the mistakes that otherwise surface as Pending
# pods or silent 401s an hour into an apply.
###############################################################################

# What AWS itself says about the GPU node groups: the GPU model and count per
# instance type, and whether that type is offered in the group's AZ. Read-only,
# and only for groups marked gpu = true.
# Only for types the offerings lookup confirms: DescribeInstanceTypes fails
# outright on a type the region does not sell, which would pre-empt the
# readable "not offered" precondition with a raw API error.
data "aws_ec2_instance_type" "gpu" {
  for_each      = local.gpu_offered_types
  instance_type = each.value
}

data "aws_ec2_instance_type_offerings" "gpu" {
  for_each      = local.gpu_groups
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [each.value.instance_type]
  }

  filter {
    name   = "location"
    values = [each.value.availability_zone]
  }
}

locals {
  # Splunk's stated minimum GPU topology for AI tier v1.0 (deployment guide):
  # 2 nodes x 1 H100, or 2 nodes x 4 L40S. The model set requests 1.67 H100s or
  # 3.3 L40S, and Gemma alone needs a whole H100 (two L40S), which is why a
  # single-GPU host cannot run it however it is tuned.
  ai_min_gpus = { H100 = 2, L40S = 8 }

  gpu_offered_types = toset([
    for k, o in data.aws_ec2_instance_type_offerings.gpu : local.gpu_groups[k].instance_type if length(o.instance_types) > 0
  ])

  gpu_total = sum(concat([0], [
    for ng in values(local.gpu_groups) : ng.desired * one(data.aws_ec2_instance_type.gpu[ng.instance_type].gpus).count
    if contains(local.gpu_offered_types, ng.instance_type)
  ]))
  gpu_models = distinct([
    for ng in values(local.gpu_groups) : one(data.aws_ec2_instance_type.gpu[ng.instance_type].gpus).name
    if contains(local.gpu_offered_types, ng.instance_type)
  ])
}

resource "terraform_data" "ai_guard" {
  count = local.enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.gpu_groups) > 0
      error_message = "ai_tier_enabled = true needs at least one eks_node_groups entry with gpu = true (e.g. instance_type = \"g6e.12xlarge\"). Without one, every Ray GPU worker stays Pending."
    }

    precondition {
      condition     = contains([for ng in values(local.gpu_groups) : ng.instance_type], var.ai_gpu_instance_type)
      error_message = "ai_gpu_instance_type (${var.ai_gpu_instance_type}) does not match the instance_type of any gpu = true node group. The AIPlatform sizes its Ray worker groups to this type, so the two must agree."
    }

    precondition {
      condition     = alltrue([for k, o in data.aws_ec2_instance_type_offerings.gpu : length(o.instance_types) > 0])
      error_message = "A gpu = true node group asks for an instance type its availability zone does not offer: ${join(", ", [for k, o in data.aws_ec2_instance_type_offerings.gpu : "${k} (${local.gpu_groups[k].instance_type} in ${local.gpu_groups[k].availability_zone})" if length(o.instance_types) == 0])}. Note g6e (L40S) is not offered in eu-west-2 at all; there, use p5 (H100)."
    }

    precondition {
      condition     = alltrue([for n in local.gpu_models : n == var.ai_accelerator_type])
      error_message = "The GPU node groups carry ${join(", ", local.gpu_models)} but ai_accelerator_type is ${var.ai_accelerator_type}. The accelerator selects which model weights are served, so the two must match (p5 = H100, g6e = L40S)."
    }

    precondition {
      condition     = local.gpu_total >= lookup(local.ai_min_gpus, var.ai_accelerator_type, 0)
      error_message = "The GPU node groups provide ${local.gpu_total} ${var.ai_accelerator_type} GPU(s); Splunk's minimum for the AI tier is ${lookup(local.ai_min_gpus, var.ai_accelerator_type, 0)} (2x p5.4xlarge for H100, 2x g6e.12xlarge for L40S). Below that the Gemma deployment never schedules and the GPUs you are paying for sit idle."
    }

    precondition {
      condition     = contains(local.standalone_sh, var.ai_search_head)
      error_message = "ai_search_head (${var.ai_search_head}) is not a standalone search head in this deployment (found: [${join(", ", local.standalone_sh)}]). AI tier v1.0 is qualified against a SOK Standalone only; add one via sok_standalone_search_heads."
    }

    precondition {
      condition     = contains(["L40S", "H100"], var.ai_accelerator_type)
      error_message = "ai_accelerator_type must be \"L40S\" or \"H100\": it selects which model weights are served."
    }

    precondition {
      condition = (
        tonumber(split(".", var.sok_operator_chart_version)[0]) > 3 ||
        (tonumber(split(".", var.sok_operator_chart_version)[0]) == 3 &&
        tonumber(split(".", var.sok_operator_chart_version)[1]) >= 2)
      )
      error_message = "The AI tier layer is built for Splunk Operator >= 3.2.0 (sok_operator_chart_version). The AI operator chart's own bundled Splunk Operator (3.0.0) is disabled here, so the cluster's SOK must be the current one."
    }
  }
}

# Qualified, not enforced: Splunk only qualified AI tier v1.0 against Splunk
# Enterprise 10.2 with Splunk AI Assistant 2.3.0. Anything else is a warning, so
# it shows on every plan without blocking an informed choice.
check "ai_splunk_version_qualified" {
  assert {
    condition     = !local.enabled || can(regex(":10\\.2(\\.|$|-)", var.sok_splunk_image))
    error_message = "AI tier v1.0 is qualified against Splunk Enterprise 10.2 only; sok_splunk_image is ${var.sok_splunk_image}. It may work, but the JWT and app contract has not been tested on this version."
  }
}

###############################################################################
# IRSA: one role for every AI tier service account, scoped to the artifacts
# bucket. No static keys; objectStorage.secretRef stays unset so the SDKs fall
# through to web identity.
###############################################################################

data "aws_iam_policy_document" "ai_trust" {
  count = local.enabled ? 1 : 0

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
      values   = [for sa in values(local.service_accounts) : "system:serviceaccount:${local.namespace}:${sa}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ai_s3" {
  count = local.enabled ? 1 : 0

  statement {
    sid       = "ArtifactsList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${local.ai_bucket_name}"]
  }

  # Read the staged weights; write task artifacts. SAIA and Ray both write.
  statement {
    sid = "ArtifactsObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["arn:aws:s3:::${local.ai_bucket_name}/*"]
  }
}

resource "aws_iam_role" "ai" {
  count = local.enabled ? 1 : 0

  name               = "splunk-sok-${local.environment}-ai-tier"
  assume_role_policy = data.aws_iam_policy_document.ai_trust[0].json
}

resource "aws_iam_role_policy" "ai_s3" {
  count = local.enabled ? 1 : 0

  name   = "ai-artifacts"
  role   = aws_iam_role.ai[0].id
  policy = data.aws_iam_policy_document.ai_s3[0].json
}

# Created here, not by the operator: the AIPlatform only names them, and IRSA
# needs the role annotation in place before the first pod starts.
resource "kubernetes_service_account_v1" "ai" {
  for_each = local.enabled ? local.service_accounts : {}

  metadata {
    name      = each.value
    namespace = local.namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ai[0].arn
    }
    labels = {
      "app.kubernetes.io/part-of"    = "splunk-ai-tier"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

###############################################################################
# NVIDIA device plugin
#
# The AL2023 NVIDIA AMI (eks layer, gpu = true) already carries the driver and
# container toolkit, so this is all that is needed to advertise nvidia.com/gpu
# to the scheduler. Pinned to the GPU nodes by the label the eks layer sets, and
# tolerating everything there so a role taint cannot strand it.
###############################################################################

resource "helm_release" "nvidia_device_plugin" {
  count = local.enabled ? 1 : 0

  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-system"
  version    = var.ai_nvidia_device_plugin_chart_version

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode(local.nvdp_values)]
}

###############################################################################
# Splunk AI Operator
#
# The chart bundles five subcharts; two are switched OFF because this estate
# already runs them, and a second copy would fight the first:
#   splunk-operator  the chart ships SOK 3.0.0; the sok layer runs 3.2.0
#   cert-manager     the sok layer installs it (certs.tf) when ai_tier_enabled
# KubeRay is needed (Ray inference) and has no other home, so it stays on.
#
# The OpenTelemetry operator is OFF, deliberately:
#   - its vendored values.schema.json is itself invalid against the JSON Schema
#     metaschema, and Helm 3.19 rejects the whole chart for it (3.17 did not
#     check). Whether it installs would otherwise depend on the Helm SDK the
#     helm provider happens to embed;
#   - neither controller watches OpenTelemetry types (v1.0.0 source), and the
#     AIPlatform's OTel sidecar is off anyway: export to an external Splunk's
#     HEC is outside what Splunk qualified for v1.0.
#
# kube-prometheus-stack is NOT optional in practice: the AIService controller
# watches ServiceMonitor, so the manager will not start without that CRD. See
# var.ai_monitoring_enabled.
#
# Images are always set explicitly: the chart's defaults are NOT the qualified
# v1.0 combination (they reference saia-api:1.1.0, slim-api:1.0.0 and stock Ray).
###############################################################################

resource "helm_release" "ai_operator" {
  count = local.enabled ? 1 : 0

  name             = "splunk-ai-operator"
  repository       = "https://github.com/splunk/splunk-ai-operator/releases/download/v${var.ai_operator_chart_version}"
  chart            = "splunk-ai-operator"
  version          = var.ai_operator_chart_version
  namespace        = "splunk-ai-operator"
  create_namespace = true

  atomic          = true
  cleanup_on_fail = true
  timeout         = 900

  # Built in images.tf: every image routed through ECR when the cache is on.
  values = [yamlencode(local.ai_operator_values)]

  depends_on = [terraform_data.ai_guard, helm_release.nvidia_device_plugin]
}

###############################################################################
# AIPlatform
#
# In the SOK namespace, not its own: the tested JWT issuer is the search head's
# SHORT service name, which only resolves from the same namespace.
###############################################################################

# Same certificate the Splunk Web ALB uses: an explicit ARN, else the newest
# ISSUED *.<zone> certificate (sok/web-ingress.tf resolves it identically).
data "aws_acm_certificate" "ai" {
  count       = local.enabled && var.ai_ingress_host != "" && var.sok_web_external_certificate_arn == "" ? 1 : 0
  domain      = "*.${var.sok_web_external_zone_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  feature_sa = { saia = local.service_accounts.saia, slim = local.service_accounts.slim }

  # jsondecode(... ? jsonencode() : jsonencode()): the two branches are objects of
  # different shapes, which a plain conditional cannot unify. The value only
  # feeds yamlencode, so a dynamic type is fine.
  ai_ingress = jsondecode(var.ai_ingress_host == "" ? jsonencode({ enabled = false }) : jsonencode({
    enabled   = true
    className = "alb"
    annotations = {
      # Share the Splunk Web ALB rather than paying for a second one.
      "alb.ingress.kubernetes.io/group.name"      = "splunk-sok-${local.environment}-web"
      "alb.ingress.kubernetes.io/scheme"          = var.sok_alb_is_internet_facing ? "internet-facing" : "internal"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/certificate-arn" = var.sok_web_external_certificate_arn != "" ? var.sok_web_external_certificate_arn : one(data.aws_acm_certificate.ai[*].arn)
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/inbound-cidrs"   = join(",", length(var.sok_web_external_allowed_cidrs) > 0 ? var.sok_web_external_allowed_cidrs : var.trusted_cidrs)
      # No healthcheck-path: SAIA's health route is undocumented (the docs only
      # give /health for SLIM). If targets show unhealthy, confirm the route on a
      # running pod and add alb.ingress.kubernetes.io/healthcheck-path here.
    }
    # No `tls` block: the CRD requires a Kubernetes TLS secretName there, but on
    # an ALB TLS terminates with the ACM certificate named in the annotation.
    hosts = [{ host = var.ai_ingress_host, paths = [{ path = "/", pathType = "Prefix" }] }]
  }))
}

resource "kubectl_manifest" "ai_platform" {
  count = local.enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "ai.splunk.com/v1"
    kind       = "AIPlatform"
    metadata   = { name = "ai", namespace = local.namespace }
    spec = {
      # Layout from Splunk's EKS guide: path s3://<bucket>/artifacts, weights
      # under artifacts/model_artifacts/<model>/, which is exactly what Ray
      # mirrors into /home/ray/.cache/s3/artifacts/model_artifacts/<model>.
      # scripts/ai-stage-models.sh uploads to that prefix.
      objectStorage = merge(
        {
          provider = "aws"
          path     = "s3://${local.ai_bucket_name}/${local.ai_artifacts_prefix}"
          region   = var.region
        },
        # IRSA by default. Set only if Ray's downloader proves to need static
        # keys (a Secret with s3_access_key / s3_secret_key).
        var.ai_object_storage_secret != "" ? { secretRef = var.ai_object_storage_secret } : {},
      )
      serviceAccountName = local.service_accounts.platform

      features = [for f in var.ai_features : merge(
        { name = f },
        contains(keys(local.feature_sa), f) ? { serviceAccountName = local.feature_sa[f] } : {},
      )]

      workerGroupConfig = { serviceAccountName = local.service_accounts.ray }

      images = {
        saiaImage           = local.image.saia_api
        weaviateImage       = local.image.weaviate
        rayHeadGroupImage   = local.image.ray_head
        rayWorkerGroupImage = local.image.ray_worker
      }

      defaultAcceleratorType = var.ai_accelerator_type
      gpuInstanceType        = var.ai_gpu_instance_type

      sidecars = {
        envoy              = true
        otel               = false
        prometheusOperator = var.ai_monitoring_enabled
      }

      # JWT-only trust of the SOK search head, on the management port. The same
      # string must be the search head's issuer_uri (docs/ai-tier.md, step 3).
      splunkConfiguration = {
        endpoint       = local.splunk_issuer
        trustedIssuers = [local.splunk_issuer]
        secretRef      = { name = local.splunk_secret, namespace = local.namespace }
      }

      storage = {
        vectorDB = {
          size             = var.ai_vector_db_storage
          storageClassName = "splunk-gp3-${var.data_volume_filesystem}"
        }
      }

      gpuScheduler = {
        nodeSelector = { "nvidia.com/gpu.present" = "true" }
        tolerations  = [{ key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" }]
      }

      clusterDomain = "cluster.local"
      ingress       = local.ai_ingress
    }
  })

  depends_on = [helm_release.ai_operator, kubernetes_service_account_v1.ai]
}
