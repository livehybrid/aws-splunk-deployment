###############################################################################
# SOK web ALB certificate, issued from the organisation's AWS Private CA.
#
# Gated entirely on var.acm_private_ca_arn. Empty (the default) creates nothing
# and the sok layer's behaviour is unchanged: it uses
# sok_web_external_certificate_arn if set, else discovers the most-recent ISSUED
# public *.<zone> certificate (web-ingress.tf).
#
# WHY THE ACCOUNT LAYER: this layer is persistent, the sok layer is destroyed
# nightly. Issuing the certificate there would mint and revoke one on every
# rebuild, churning the CA's issuance record (and, on a public CA, burning
# rate limits) for a value that never changes. Here it is issued once and
# survives every teardown, exactly like the SmartStore bucket and HEC token.
#
# NO VALIDATION STEP: ACM issues from a private CA immediately, so unlike a
# public certificate there is no aws_acm_certificate_validation resource and no
# DNS validation records to publish. The cost is that clients must trust the
# org root, which is why this pairs with an internal ALB
# (sok_alb_is_internet_facing = false).
#
# COVERAGE: the sok layer puts every exposed component on a SINGLE label under
# the zone (<first-label-of-hostname>-<component>.<zone>, see
# local.web_component_hosts), so one *.<zone> wildcard covers all of them. The
# apex rides along as a SAN so sok_web_external_hostname still resolves if it is
# ever set to the bare zone.
###############################################################################

resource "aws_acm_certificate" "sok_web" {
  count = var.acm_private_ca_arn != "" ? 1 : 0

  certificate_authority_arn = var.acm_private_ca_arn
  domain_name               = "*.${var.sok_web_external_zone_name}"
  subject_alternative_names = [var.sok_web_external_zone_name]

  tags = {
    Name = "splunk-sok-${var.environment}-web"
  }

  lifecycle {
    # The ALB listener references this ARN; replacing the cert (a CA change, a
    # domain change) must create the new one before the old one goes.
    create_before_destroy = true

    precondition {
      condition     = var.sok_web_external_zone_name != ""
      error_message = "acm_private_ca_arn is set but sok_web_external_zone_name is empty, so the certificate would be issued for '*.' Set sok_web_external_zone_name to the zone the SOK ALB hostnames live under."
    }
  }
}

# Feed this into the sok layer's sok_web_external_certificate_arn. Deliberately
# not auto-discovered there: the sok layer's data.aws_acm_certificate lookup is
# domain + most_recent, which cannot tell a private-CA certificate from a public
# one for the same *.<zone> and would silently pick whichever was issued last.
output "sok_web_certificate_arn" {
  description = "ARN of the private-CA certificate for the SOK web ALB, or null when acm_private_ca_arn is unset. Set sok_web_external_certificate_arn to this value in the sok layer's tfvars."
  value       = one(aws_acm_certificate.sok_web[*].arn)
}