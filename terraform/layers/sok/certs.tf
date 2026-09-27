###############################################################################
# TLS from AWS Private CA (ACM PCA) for the Splunk components.
#
# See docs/private-ca-tls.md for the design, the traps and the pass
# criteria.
#
# ⚠ EVERYTHING HERE IS GATED ON var.sok_private_ca_enabled, WHICH DEFAULTS TO
#   false. With the toggle off this file creates no resources, requires no new
#   IAM and produces no plan diff.
#
# ── Why this is built the way it is (SOK 3.2.0) ──────────────────────────────
#
# 3.2.0 added native certificate management: `spec.certs[]` on every Splunk CR,
# with roles `server` (splunkd 8089) and `input` (S2S 9997). The operator mounts
# the Secret and writes the Splunk TLS config itself, which replaces the conf
# overlay this file used to carry. Two consequences worth knowing:
#
#   1. The operator's auto-generation path is NOT usable here. Its
#      `issuerRef.kind` is an enum of exactly {Issuer, ClusterIssuer} with no
#      `group` field, so it cannot reference an AWSPCAClusterIssuer
#      (group awspca.cert-manager.io). We therefore use the operator's
#      "bring your own Secret" path, which its own docs call the recommended
#      one: WE own the cert-manager Certificate, the operator just consumes the
#      Secret it produces.
#
#   2. The operator wants tls.crt / tls.key / ca.crt, which is exactly
#      cert-manager's native Secret shape. No combined PEM, and no
#      initContainer to build one (the CRD has no initContainers field at all).
#
# BRING YOUR OWN CA. This does not create the certificate authority. It reuses
# var.acm_private_ca_arn, the same organisation CA account/acm.tf can issue
# the web ALB certificate from.
#
# What it does:
#   1. installs cert-manager and aws-privateca-issuer,
#   2. gives the issuer an IRSA role scoped to that one CA ARN,
#   3. issues one leaf certificate per Splunk CR into a Kubernetes Secret,
#   4. exposes local.tls_certs_for, which crs.tf hands to spec.certs[].
###############################################################################

locals {
  tls_enabled = var.sok_private_ca_enabled

  # One cert per CR. Keys must match the CR names built in crs.tf.
  tls_cr_kinds = merge(
    {
      lm = "license-manager"
      mc = "monitoring-console"
      cm = "cluster-manager"
    },
    var.multisite
    ? { for site in keys(local.sites) : "idxc-${site}" => "indexer" }
    : { idxc = "indexer" },
    { for k in keys(local.sh_map) : "sh-${k}" => "standalone" },
    { for k in keys(local.shc_map) : "shc-${k}" => "search-head" },
  )

  tls_secret_for = { for cr, _ in local.tls_cr_kinds : cr => "splunk-${cr}-tls" }

  # SANs. The operator can auto-derive these, but only for the auto-generation
  # path we cannot use, so we build them ourselves to the same shape it
  # documents: the Service FQDN, plus a wildcard over the headless Service for
  # per-pod DNS (peers address each other by pod FQDN for replication, bundle
  # push and distributed search).
  #
  # ⚠ Indexers also carry the externally dialled S2S name. Through the S2S NLB
  # (TCP passthrough) TLS terminates on the pod but the forwarder dialled the
  # NLB/Route53 name, so without it as a SAN every forwarder fails
  # sslVerifyServerCert and ingestion stops. Auto-derived SANs would never
  # include it either, which is exactly why we set them explicitly.
  tls_dns_names = {
    for cr, kind in local.tls_cr_kinds : cr => concat(
      [
        "splunk-${cr}-${kind}-service",
        "splunk-${cr}-${kind}-service.${local.namespace}.svc",
        "splunk-${cr}-${kind}-service.${local.namespace}.svc.cluster.local",
        "*.splunk-${cr}-${kind}-headless.${local.namespace}.svc.cluster.local",
      ],
      kind == "indexer" ? var.sok_private_ca_s2s_sans : [],
    )
  }

  # The spec.certs[] fragment per CR, consumed by crs.tf. Empty when disabled,
  # so every CR renders exactly as it does today.
  #
  # One Secret, referenced once per role. The SAN set covers both the in-cluster
  # names (server, 8089) and the external S2S name (input, 9997), so there is no
  # reason to mint two certificates.
  #
  # requireClientCert is NOT expressible here: the operator owns that config for
  # both roles. On 8089 that is what we want anyway, since the operator presents
  # no client certificate and its REST client is InsecureSkipVerify, so mutual
  # TLS there would break reconciliation and the probes.
  tls_certs_for = {
    for cr, kind in local.tls_cr_kinds : cr => local.tls_enabled ? concat(
      [
        { secretRef = { name = local.tls_secret_for[cr] }, role = "server" },
      ],
      kind == "indexer" && var.sok_private_ca_s2s_enabled ? [
        { secretRef = { name = local.tls_secret_for[cr] }, role = "input" },
      ] : [],
    ) : []
  }
}

###############################################################################
# cert-manager
#
# Installed here rather than via the Splunk Operator chart's optional
# cert-manager dependency, because the issuer below needs it in a known
# namespace with a known ServiceAccount for IRSA, and because the operator chart
# ships it disabled by default anyway.
###############################################################################

resource "helm_release" "cert_manager" {
  # Also for the AI tier: the Splunk AI Operator's admission webhooks get their
  # serving certificates from cert-manager (terraform/layers/ai). One install
  # serves both; the AI operator chart's bundled cert-manager is disabled.
  count = local.tls_enabled || var.ai_tier_enabled ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  version          = var.sok_cert_manager_chart_version
  create_namespace = true

  # Same reasoning as the ALB controller: a failed install otherwise strands a
  # `failed` release that terraform never records, and the next apply dies with
  # "cannot re-use a name that is still in use".
  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    },
    # All cert-manager images live under quay.io/jetstack; one switch moves them
    # to the ECR pull-through cache for a VPC with no internet egress.
    {
      name  = "imageRegistry"
      value = local.ecr_cache ? "${local.ecr_registry}/quay-public" : "quay.io"
    },
  ]
}

###############################################################################
# IRSA for aws-privateca-issuer
#
# Scoped to the one CA ARN. No static keys, matching every other role here.
###############################################################################

data "aws_iam_policy_document" "privateca_issuer_trust" {
  count = local.tls_enabled ? 1 : 0

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
      values   = ["system:serviceaccount:cert-manager:aws-privateca-issuer"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "privateca_issuer" {
  count = local.tls_enabled ? 1 : 0

  statement {
    sid = "IssueFromNamedCaOnly"
    actions = [
      "acm-pca:DescribeCertificateAuthority",
      "acm-pca:GetCertificate",
      "acm-pca:IssueCertificate",
    ]
    resources = [var.acm_private_ca_arn]
  }
}

resource "aws_iam_role" "privateca_issuer" {
  count = local.tls_enabled ? 1 : 0

  # local.environment (lower-cased), matching every other resource name here,
  # so a mixed-case environment value cannot produce a mismatched role name.
  name               = "splunk-sok-${local.environment}-privateca-issuer"
  assume_role_policy = data.aws_iam_policy_document.privateca_issuer_trust[0].json
}

resource "aws_iam_role_policy" "privateca_issuer" {
  count = local.tls_enabled ? 1 : 0

  name   = "privateca-issuer"
  role   = aws_iam_role.privateca_issuer[0].id
  policy = data.aws_iam_policy_document.privateca_issuer[0].json
}

resource "helm_release" "privateca_issuer" {
  count = local.tls_enabled ? 1 : 0

  name       = "aws-privateca-issuer"
  repository = "https://cert-manager.github.io/aws-privateca-issuer"
  chart      = "aws-privateca-issuer"
  namespace  = "cert-manager"
  version    = var.sok_privateca_issuer_chart_version

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  set = [
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "image.repository"
      value = local.ecr_cache ? "${local.ecr_registry}/ecr-public/k1n1h4h4/cert-manager-aws-privateca-issuer" : "public.ecr.aws/k1n1h4h4/cert-manager-aws-privateca-issuer"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-privateca-issuer"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.privateca_issuer[0].arn
    },
  ]

  depends_on = [helm_release.cert_manager]
}

###############################################################################
# Issuer + leaf certificates
###############################################################################

resource "kubectl_manifest" "privateca_cluster_issuer" {
  count = local.tls_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "awspca.cert-manager.io/v1beta1"
    kind       = "AWSPCAClusterIssuer"
    metadata   = { name = "splunk-private-ca" }
    spec = {
      arn    = var.acm_private_ca_arn
      region = var.region
    }
  })

  depends_on = [helm_release.privateca_issuer]
}

resource "kubectl_manifest" "splunk_certificate" {
  for_each = local.tls_enabled ? local.tls_cr_kinds : {}

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "splunk-${each.key}-tls", namespace = local.namespace }
    spec = {
      secretName = local.tls_secret_for[each.key]
      commonName = "splunk-${each.key}-${each.value}-service.${local.namespace}.svc.cluster.local"
      dnsNames   = local.tls_dns_names[each.key]

      duration    = var.sok_private_ca_leaf_duration
      renewBefore = var.sok_private_ca_renew_before

      privateKey = {
        algorithm = "RSA"
        size      = 2048
        # Splunk re-reads its certificate only on restart, so rotating the key in
        # place buys nothing and costs a restart. Never rotate on renewal.
        rotationPolicy = "Never"
      }

      # server auth for 8089 and the S2S listener; client auth because an
      # indexer is also a client on the replication path.
      usages = ["server auth", "client auth"]

      issuerRef = {
        group = "awspca.cert-manager.io"
        kind  = "AWSPCAClusterIssuer"
        name  = "splunk-private-ca"
      }
    }
  })

  depends_on = [kubectl_manifest.privateca_cluster_issuer]
}

###############################################################################
# Guards
#
# Fail at plan time rather than half-applying, on the two mistakes that are easy
# to make and expensive to unpick.
###############################################################################

resource "terraform_data" "private_ca_guard" {
  count = local.tls_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws[a-z-]*:acm-pca:", var.acm_private_ca_arn))
      error_message = "sok_private_ca_enabled = true requires acm_private_ca_arn to be an ACM PCA certificate-authority ARN. This module does NOT create the CA: pass the ARN of an existing organisation ACM PCA (the same one account/acm.tf can issue the web ALB certificate from)."
    }

    precondition {
      # spec.certs[] and the CertManagement gate both arrived in 3.2.0. On an
      # older chart helm silently drops the unknown `featureGates` value and the
      # older CRDs reject (or ignore) spec.certs[], so the whole thing no-ops
      # with no error anywhere. Fail loudly instead.
      condition = !var.sok_private_ca_enabled || (
        tonumber(split(".", var.sok_operator_chart_version)[0]) > 3 ||
        (tonumber(split(".", var.sok_operator_chart_version)[0]) == 3 &&
        tonumber(split(".", var.sok_operator_chart_version)[1]) >= 2)
      )
      error_message = "sok_private_ca_enabled = true requires sok_operator_chart_version >= 3.2.0 (spec.certs[] and the CertManagement feature gate were added there). Bump the chart version AND re-vendor sok/files/splunk-operator-crds.yaml from the matching release: the two must move together."
    }

    precondition {
      condition     = !var.sok_private_ca_s2s_enabled || length(var.sok_private_ca_s2s_sans) > 0
      error_message = "sok_private_ca_s2s_enabled = true requires sok_private_ca_s2s_sans (the externally dialled S2S name, e.g. [\"s2s.example.com\"]). Through the S2S NLB the forwarder dials that name, not the pod service name, so without it as a SAN every forwarder fails sslVerifyServerCert and ingestion stops. If you are testing pod-to-pod 8089 only, set sok_private_ca_s2s_enabled = false."
    }
  }
}
