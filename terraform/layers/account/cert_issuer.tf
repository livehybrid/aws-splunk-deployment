###############################################################################
# Certificate-issuing Lambda: signs CSRs from Splunk instances with the
# internal root CA (pki_ca.tf). Instances reach it by naming convention
# (splunk-cert-issuer-<environment>) using lambda:InvokeFunction from their
# instance role; the CA *private key* in ma-certs is readable only by this
# function's role.
###############################################################################

module "cert_issuer" {
  source = "../../modules/cert_issuer"

  name          = "splunk-cert-issuer-${var.environment}"
  ca_bucket     = aws_s3_bucket.ma-certs.bucket
  ca_key_object = aws_s3_object.root_ca_key.key
  ca_crt_object = aws_s3_object.root_ca_crt.key
  kms_key_arn   = aws_kms_key.pki.arn

  # CSR CN/SANs must fall under one of these suffixes.
  allowed_dns_suffixes = "${var.environment}.splunk.internal,${var.dns_base_domain}"
}

output "cert_issuer_function_name" {
  value = module.cert_issuer.function_name
}
