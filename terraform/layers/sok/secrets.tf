###############################################################################
# The operator's global secret: splunk-<namespace>-secret.
#
# Key names are EXACT, from operator source (GetSplunkSecretTokenTypes):
#   password, pass4SymmKey, idxc_secret, shc_secret, hec_token
# (PasswordManagement.md's prose spells some differently, the prose is
# wrong; a mistyped key is silently replaced by an operator-generated value.)
#
# Sources are var-driven (SEC-1): prod defaults to the estate's legacy shared
# secrets (/monitoring/splunk/password + /splunk/pass4SymmKey, one key for idx
# clustering and SHC, kept for bucket/config compatibility); dev points at the
# env-scoped /dev/splunk/* trio so dev pods never hold prod credentials. A path
# change rotates at the next rebuild (the cluster re-forms with the new values;
# SmartStore data is independent of pass4SymmKey). The HEC token is now PERSISTENT
# (OPS-14): the sok-foundation layer (not part of the nightly teardown) creates
# and seeds /<env>/splunk/hec_token once, and this layer just READS it, so the
# token is stable across every destroy/recreate cycle instead of regenerating.
#
# The operator back-fills empty keys and adds ownerReferences to this object;
# both are tolerated (no reconciling controller fighting it).
###############################################################################

data "aws_secretsmanager_secret_version" "admin_password" {
  secret_id = var.sok_secret_admin_password_id
}

data "aws_secretsmanager_secret_version" "pass4symmkey" {
  secret_id = var.sok_secret_pass4symmkey_id
}

data "aws_secretsmanager_secret_version" "license" {
  secret_id = var.sok_secret_license_id
}

# Persistent HEC token (OPS-14): read the foundation-seeded secret rather than
# minting a fresh random_uuid every rebuild. Foundation creates/seeds it once
# (sok-foundation/hec-token.tf, ignore_changes so it never rotates on re-apply).
data "aws_secretsmanager_secret_version" "hec_token" {
  secret_id = var.sok_secret_hec_token_id
}

resource "kubernetes_secret_v1" "global" {
  metadata {
    name      = "splunk-${local.namespace}-secret"
    namespace = local.namespace
  }

  data = {
    password     = data.aws_secretsmanager_secret_version.admin_password.secret_string
    pass4SymmKey = data.aws_secretsmanager_secret_version.pass4symmkey.secret_string
    idxc_secret  = data.aws_secretsmanager_secret_version.pass4symmkey.secret_string
    shc_secret   = data.aws_secretsmanager_secret_version.pass4symmkey.secret_string
    hec_token    = data.aws_secretsmanager_secret_version.hec_token.secret_string
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}

# Enterprise licence blob for the LicenseManager CR, mounted at
# /mnt/licenses/enterprise.lic (CR volumes are mounted at /mnt/<name>).
resource "kubernetes_secret_v1" "license" {
  metadata {
    name      = "splunk-licenses"
    namespace = local.namespace
  }

  data = {
    "enterprise.lic" = data.aws_secretsmanager_secret_version.license.secret_string
  }

  depends_on = [kubernetes_namespace_v1.splunk]
}
