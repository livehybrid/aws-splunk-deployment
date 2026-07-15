###############################################################################
# Persistent HEC token (OPS-14).
#
# The operator's global secret carries a hec_token used by every HEC input.
# It USED to be minted by random_uuid in the sok layer, so it regenerated on
# every nightly sok destroy/recreate — anything sending HEC (external
# forwarders, the estate's own tooling) had to be re-tokened after each rebuild.
#
# Persist it here instead: the foundation layer is NEVER part of the nightly
# teardown, so a token stored in it survives every rebuild. It mirrors the other
# SOK secrets' flow exactly (admin_password/pass4symmkey/license are Secrets
# Manager secrets read by the sok layer via aws_secretsmanager_secret_version) —
# the difference is that those are pre-existing estate secrets, whereas this one
# is foundation-owned, so foundation both CREATES and SEEDS it.
#
# create-if-not-exists, never rotate on re-apply:
#   - random_uuid keeps the value stable in state across applies;
#   - ignore_changes = [secret_string] on the version means a re-apply neither
#     rewrites nor rotates the stored token (it is written once, on first apply).
# To rotate deliberately: taint random_uuid.hec_token and remove the
# ignore_changes guard for one apply, or update the secret value out of band.
###############################################################################

resource "random_uuid" "hec_token" {}

resource "aws_secretsmanager_secret" "hec_token" {
  name        = "/${var.environment}/splunk/hec_token"
  description = "Persistent HEC token for the SOK global secret (survives the nightly rebuild) — OPS-14."

  tags = {
    project     = "splunk"
    Name        = "splunk-hec-token-${var.environment}"
    Environment = var.environment
  }

  # The token every HEC sender relies on — never let a destroy take it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "hec_token" {
  secret_id     = aws_secretsmanager_secret.hec_token.id
  secret_string = random_uuid.hec_token.result

  # Created-if-not-exists: seed the token on first apply, then leave it alone so
  # re-applies never rotate it (that would defeat the whole point of OPS-14).
  lifecycle {
    ignore_changes = [secret_string]
  }
}
