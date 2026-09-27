###############################################################################
# Image routing, so the AI tier runs in a VPC with no internet egress.
#
# With use_ecr_pullthrough_cache on, every image goes through the account
# layer's ECR pull-through cache (account/ecr.tf). ECR fetches from the upstream
# on AWS's side, so nodes only ever talk to ECR through the VPC's ECR endpoints.
#
#   docker.io        -> docker-public   (needs the Docker Hub credential secret)
#   quay.io          -> quay-public
#   registry.k8s.io  -> k8s-public
#   public.ecr.aws   -> ecr-public
#
# nvcr.io (the NVIDIA device plugin) is NOT a supported pull-through upstream.
# Mirror it once with scripts/mirror-device-plugin.sh and set
# ai_nvidia_device_plugin_image.
#
# Model weights never come from Hugging Face at runtime: every model loads from
# the artifacts bucket (or is baked into the Ray image), so the cluster needs S3,
# not the internet. See docs/ai-tier.md.
#
# Chart values are overridden per image `registry` (or `repository`), leaving
# tags to the chart, so a chart bump does not need touching here. With the cache
# off, every value resolves to its upstream registry, the charts' own defaults.
###############################################################################

locals {
  cache = var.use_ecr_pullthrough_cache

  ecr_prefix = {
    "docker.io"       = "docker-public"
    "quay.io"         = "quay-public"
    "registry.k8s.io" = "k8s-public"
    "public.ecr.aws"  = "ecr-public"
  }

  # The value for a chart's `registry` field, per upstream.
  registry = { for up, p in local.ecr_prefix : up => local.cache ? "${local.ecr_registry}/${p}" : up }

  # docker.io references the operator injects into the pods it creates.
  image = { for k, ref in var.ai_images : k => local.cache ? "${local.ecr_registry}/docker-public/${trimprefix(ref, "docker.io/")}" : ref }

  # The operator's two remaining injected images, at the AI operator 1.0.0
  # chart's defaults. Docker Hub official images need `library/` through ECR.
  aux_image = { for k, ref in {
    otel  = "docker.io/otel/opentelemetry-collector-contrib:0.122.1"
    nginx = "docker.io/library/nginx:1.27-alpine"
    # Only used if the operator deploys its own bundled Splunk, which is off here
    # (the AI tier uses the SOK search head). Routed so nothing points outside.
    splunk = "docker.io/splunk/splunk:10.2.0"
  } : k => local.cache ? "${local.ecr_registry}/docker-public/${trimprefix(ref, "docker.io/")}" : ref }

  ai_operator_values = {
    # See main.tf for why these two are off.
    "splunk-operator"        = { enabled = false }
    "cert-manager"           = { enabled = false }
    "opentelemetry-operator" = { enabled = false }

    "kuberay-operator" = {
      enabled = true
      image   = { repository = "${local.registry["quay.io"]}/kuberay/operator" }
    }

    # Every image kube-prometheus-stack and its Linux subcharts can run.
    # Grafana is disabled by the AI operator chart; the Windows exporter never
    # schedules on these Linux nodes.
    "kube-prometheus-stack" = {
      enabled = var.ai_monitoring_enabled
      crds = { upgradeJob = { image = {
        busybox = { registry = local.registry["docker.io"], repository = "library/busybox" }
        kubectl = { registry = local.registry["registry.k8s.io"] }
      } } }
      alertmanager = { alertmanagerSpec = { image = { registry = local.registry["quay.io"] } } }
      prometheusOperator = {
        image                    = { registry = local.registry["quay.io"] }
        prometheusConfigReloader = { image = { registry = local.registry["quay.io"] } }
        thanosImage              = { registry = local.registry["quay.io"] }
        admissionWebhooks = {
          deployment = { image = { registry = local.registry["quay.io"] } }
          patch      = { image = { registry = local.registry["registry.k8s.io"] } }
        }
      }
      prometheus  = { prometheusSpec = { image = { registry = local.registry["quay.io"] } } }
      thanosRuler = { thanosRulerSpec = { image = { registry = local.registry["quay.io"] } } }
      "kube-state-metrics" = {
        image         = { registry = local.registry["registry.k8s.io"] }
        kubeRBACProxy = { image = { registry = local.registry["quay.io"] } }
      }
      "prometheus-node-exporter" = {
        image         = { registry = local.registry["quay.io"] }
        kubeRBACProxy = { image = { registry = local.registry["quay.io"] } }
      }
    }

    image = {
      repository = "${local.registry["docker.io"]}/splunk/splunk-ai-operator"
      tag        = "v${var.ai_operator_chart_version}"
    }

    saiaApiImage          = local.image.saia_api
    saiaApiV2Image        = local.image.saia_api_v2
    saiaSchemaImage       = local.image.saia_data_loader
    slimApiImage          = local.image.slim
    rayHeadImage          = local.image.ray_head
    rayWorkerImage        = local.image.ray_worker
    weaviateImage         = local.image.weaviate
    otelCollectorImage    = local.aux_image.otel
    nginxImage            = local.aux_image.nginx
    splunkEnterpriseImage = local.aux_image.splunk
  }

  # repo:tag split of the mirrored device-plugin image, when one is set.
  nvdp_image = var.ai_nvidia_device_plugin_image == "" ? null : regex("^(?P<repository>.+):(?P<tag>[^:/]+)$", var.ai_nvidia_device_plugin_image)

  nvdp_values = merge(
    {
      nodeSelector = { "nvidia.com/gpu.present" = "true" }
      tolerations  = [{ operator = "Exists" }]
    },
    local.nvdp_image == null ? {} : { image = local.nvdp_image },
  )
}

# The one image the cache cannot serve. With the cache on, the deployment is
# probably meant to run without internet; say so on every plan rather than let
# the device plugin sit in ImagePullBackOff and every GPU node look empty.
check "ai_device_plugin_image_mirrored" {
  assert {
    condition     = !local.enabled || !local.cache || var.ai_nvidia_device_plugin_image != ""
    error_message = "use_ecr_pullthrough_cache is on, but the NVIDIA device plugin still pulls from nvcr.io, which ECR pull-through cache cannot serve. Fine if nodes have internet egress; otherwise run scripts/mirror-device-plugin.sh and set ai_nvidia_device_plugin_image, or no GPU will ever be advertised."
  }
}
