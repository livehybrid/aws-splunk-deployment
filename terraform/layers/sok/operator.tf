###############################################################################
# Namespace, CRDs and the Splunk Operator.
#
# These live in the sok layer, NOT the eks layer, on purpose: the alekc/kubectl
# provider configures eagerly at plan time and fails when its host is unknown,
# so it cannot run in the same apply that creates the cluster. Here the provider
# host comes from the eks layer's remote-state outputs, a concrete value at
# plan time (eks is always applied first), so plan and apply are both clean.
#
# Ordering within this layer: namespace -> CRDs -> operator (controller-runtime
# crash-loops if its CRDs are absent at pod start) -> secret/SA/ConfigMaps ->
# CRs. Cross-resource references and depends_on below encode that.
###############################################################################

resource "kubernetes_namespace_v1" "splunk" {
  metadata {
    name = local.namespace
  }

  # On destroy: strip finalizers from any stuck resources so the namespace
  # doesn't hang waiting for controllers that have already been removed.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      NS="${self.metadata[0].name}"
      # Private endpoint? export K8S_PROXY (e.g. socks5://localhost:1080) before
      # destroying: a destroy-time provisioner cannot read var.k8s_proxy_url.
      [ -n "$${K8S_PROXY:-}" ] && export HTTPS_PROXY="$K8S_PROXY"

      # Delete PVCs explicitly — EBS detach can block namespace GC otherwise
      kubectl delete pvc --all -n "$NS" --ignore-not-found --timeout=60s || true

      # Strip finalizers from standard workload resources
      for resource in pods statefulsets deployments; do
        kubectl get "$resource" -n "$NS" -o name 2>/dev/null | while read obj; do
          kubectl patch "$obj" -n "$NS" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        done
      done

      # Strip finalizers from Ingresses (ALB controller sets ingress.k8s.aws/resources
      # and won't clear it once the controller is destroyed)
      kubectl get ingress -n "$NS" -o name 2>/dev/null | while read obj; do
        kubectl patch "$obj" -n "$NS" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
      done

      # Strip finalizers from TargetGroupBindings (ALB controller CRD; each Ingress
      # rule creates one, and they block namespace deletion after the controller is gone)
      kubectl get targetgroupbinding -n "$NS" -o name 2>/dev/null | while read obj; do
        kubectl patch "$obj" -n "$NS" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
      done

      # Strip the namespace finalizer itself as a last resort
      kubectl get namespace "$NS" -o name 2>/dev/null && \
        kubectl patch namespace "$NS" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    EOF
  }
}

# CRDs were REMOVED from the Helm chart in 3.0.0 (Helm's ~1MB object limit) and
# must be applied out-of-band. The release asset is vendored at
# files/splunk-operator-crds.yaml
#   source: https://github.com/splunk/splunk-operator/releases/download/3.1.0/splunk-operator-crds.yaml
#   sha256: d974a6f2c768ad60d8eb56b2dc571354b4dfe48873cbff4e478ca6aa3e2fb3fe
# Split with a local expression rather than data.kubectl_file_documents (a data
# source is read at plan time, which would force the kubectl provider to
# configure, unnecessary here but avoided for symmetry with the CR resources).
# Applied server-side: client-side apply trips the annotation-size limit on
# these ~1MB CRDs. The bundle has no in-content "---" (verified: 10 separators,
# 11 CustomResourceDefinition docs), so a newline split is exact; each doc is
# keyed by its metadata.name so state addresses stay stable. Bump the vendored
# file and var.sok_operator_chart_version together.
locals {
  default_splunk_image = "${local.ecr_registry}/docker-public/${trimprefix(var.sok_splunk_image, "docker.io/")}"

  sok_crd_docs = {
    for doc in compact(split("\n---\n", file("${path.module}/files/splunk-operator-crds.yaml"))) :
    yamldecode(doc).metadata.name => doc
  }
}

resource "kubectl_manifest" "sok_crds" {
  for_each = local.sok_crd_docs

  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}

# Operator install: SAME namespace as the Splunk CRs. A namespace-scoped
# operator only watches its own namespace (WATCH_NAMESPACE = release namespace),
# so operator-in-one-namespace / CRs-in-another leaves every CR Pending forever
# with no error. clusterWideAccess=false keeps it namespace-scoped.
#
# Chart value keys verified against the 3.1.0 chart's values.yaml +
# templates/deployment.yaml, do not rename casually.
resource "helm_release" "splunk_operator" {
  name       = "splunk-operator"
  repository = "https://splunk.github.io/splunk-operator/"
  chart      = "splunk-operator"
  version    = var.sok_operator_chart_version
  namespace  = kubernetes_namespace_v1.splunk.metadata[0].name

  # On a fresh cluster the operator can sit Pending for minutes while the EBS CSI
  # provisions its app-staging PVC (WaitForFirstConsumer), longer than helm's
  # 5-min default wait, which then fails the apply. 15 min covers the slow first
  # boot (nightly recreate / multisite bring-up).
  timeout = 900

  # Without this a failed install leaves the release in `failed` state while
  # terraform records nothing in state, so the retry dies with "cannot re-use a
  # name that is still in use" and the only way forward is a manual
  # `helm delete -n splunk splunk-operator`. atomic uninstalls the failed
  # install (the CRDs are applied out-of-band above, so they survive) and
  # cleanup_on_fail removes resources a failed UPGRADE created, making
  # `terraform apply` retryable on its own.
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    image = {
      # RELATED_IMAGE_SPLUNK_ENTERPRISE, the default Splunk image; every CR
      # also pins spec.image explicitly.
      repository = local.default_splunk_image
    }
    splunkOperator = {
      image = {
        repository = "${local.ecr_registry}/docker-public/splunk/splunk-operator:${var.sok_operator_chart_version}"
      }
      clusterWideAccess = false
      # (certs.tf) spec.certs[] is behind the CertManagement feature gate,
      # added in 3.2.0 and OFF by default. Without it the operator silently
      # ignores spec.certs[] rather than erroring, so the CRs come up with
      # Splunk's own self-signed certs and nothing says why. Empty map when the
      # toggle is off, which is the chart default and no diff.
      featureGates = var.sok_private_ca_enabled ? { CertManagement = true } : {}
      # Mandatory for Splunk 10.x: containers refuse to start without the
      # Splunk General Terms acceptance flag. Sourced from a variable with no
      # accepting default (dev sets it in tfvars).
      splunkGeneralTerms = var.sok_accept_splunk_general_terms
      persistentVolumeClaim = {
        # App Framework staging area, without a PVC the operator stages app
        # downloads in RAM.
        storageClassName = local.storage_class
      }
      # IRSA for the App Framework Download phase: the chart stamps these onto
      # the operator ServiceAccount (and Deployment), so the operator pod reads
      # the apps bucket via web-identity, no static keys. (appframework.tf)
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.operator_apps.arn
      }
      # Trim the chart's 1000m/2000Mi default, the operator is light when
      # managing a handful of dev CRs, and this frees ~900m CPU on the single
      # node. It still bursts to the limit if a reconcile storm hits.
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }
    }
  })]

  # alb_controller: nothing here consumes it, but both helm releases would
  # otherwise be created CONCURRENTLY, and the ALB controller registers
  # admission webhooks that intercept objects this chart creates. Serialising
  # on it means the controller's pods are Ready (helm waits) before anything
  # else is submitted, so a slow controller rollout can never fail this
  # install. Belt and braces with enableServiceMutatorWebhook=false: that
  # removes the Service interception, this removes the ordering luck.
  depends_on = [
    kubectl_manifest.sok_crds,
    aws_iam_role_policy.operator_apps,
    helm_release.alb_controller,
  ]
}