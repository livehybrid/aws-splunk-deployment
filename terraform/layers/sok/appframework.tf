###############################################################################
# App Framework: git -> S3 (apps bucket) -> operator Download -> PodCopy.
#
# ONLY the operator pod reads the apps bucket (Download phase); Splunk pods
# receive apps via PodCopy, so the SmartStore IRSA (splunk-idx) does not cover
# this. The operator's own ServiceAccount (splunk-operator-controller-manager,
# created by the helm chart) gets S3 read + kms:Decrypt via this role, attached
# through splunkOperator.annotations in the helm values (operator.tf).
#
# Apps bucket lives in the persistent account layer; discovered here by
# naming convention (same as the SmartStore bucket).
###############################################################################

data "aws_s3_bucket" "apps" {
  bucket = "${local.bucket_root}-splunk-apps-${local.environment}"
}

data "aws_iam_policy_document" "operator_apps_trust" {
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
      values   = ["system:serviceaccount:${local.namespace}:splunk-operator-controller-manager"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "operator_apps" {
  statement {
    sid       = "AppsList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [data.aws_s3_bucket.apps.arn]
  }

  statement {
    sid       = "AppsRead"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.apps.arn}/*"]
  }

  statement {
    sid       = "AppsKms"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [data.aws_kms_alias.smartstore.target_key_arn]
  }
}

resource "aws_iam_role" "operator_apps" {
  name               = "splunk-sok-${local.environment}-operator-apps"
  assume_role_policy = data.aws_iam_policy_document.operator_apps_trust.json
}

resource "aws_iam_role_policy" "operator_apps" {
  name   = "apps"
  role   = aws_iam_role.operator_apps.id
  policy = data.aws_iam_policy_document.operator_apps.json
}

locals {
  # App Framework volume (S3, IRSA, no secretRef). Reused by the CR appRepos.
  appframework_volume = {
    name        = "appvol"
    storageType = "s3"
    provider    = "aws"
    path        = data.aws_s3_bucket.apps.bucket
    endpoint    = "https://s3.${var.region}.amazonaws.com"
    region      = var.region
  }

  # The bucket layout, rendered by the app_locations output (outputs.tf) so an
  # operator can see where to drop a .tgz without reading the CR bodies.
  #
  # ⚠ The three fixed prefixes are duplicated from the appSources in crs.tf
  # (ClusterManager + MonitoringConsole); change one, change the other. The
  # SH/SHC entries are derived from local.{sh,shc}_map, which is what the CRs
  # use too, so those cannot drift.
  #
  # Keyed by appSource NAME, not by S3 URI: two search heads may legitimately
  # share a prefix (both set app_location = "sh-apps/"), and a for-expression
  # keyed on a duplicate URI fails the whole apply.
  app_sources = merge(
    {
      "idx-apps" = {
        location        = "idx-apps/"
        scope           = "cluster"
        installs_to     = "All indexer peers, staged by the CM and shipped in the cluster bundle"
        custom_resource = "ClusterManager/cm"
      }
      "cm-apps" = {
        location        = "cm-apps/"
        scope           = "local"
        installs_to     = "Cluster manager pod only"
        custom_resource = "ClusterManager/cm"
      }
      "mc-apps" = {
        location        = "mc-apps/"
        scope           = "local"
        installs_to     = "Monitoring console pod only"
        custom_resource = "MonitoringConsole/mc"
      }
    },
    { for k, v in local.sh_map : "sh-${k}-apps" => {
      location        = v.app_location
      scope           = "local"
      installs_to     = "Standalone search head '${k}' only"
      custom_resource = "Standalone/sh-${k}"
    } },
    { for k, v in local.shc_map : "shc-${k}-apps" => {
      location        = v.app_location
      scope           = "cluster"
      installs_to     = "Search head cluster '${k}': staged in etc/shcluster/apps on the deployer, pushed to all ${v.replicas} members"
      custom_resource = "SearchHeadCluster/shc-${k}"
    } },
  )
}