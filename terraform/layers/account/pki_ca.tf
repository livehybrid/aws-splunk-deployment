###############################################################################
# Self-signed internal PKI CA used by the Splunk cluster for splunkd TLS.
#
# Lambda-managed cert issuance is driven from the cluster layer; this file
# only creates and publishes the root CA cert+key to the ma-certs S3 bucket.
###############################################################################

resource "tls_private_key" "root_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P521"
}

resource "tls_self_signed_cert" "root_ca" {
  private_key_pem = tls_private_key.root_ca.private_key_pem

  validity_period_hours = 43800
  early_renewal_hours   = 8760

  is_ca_certificate = true
  allowed_uses      = ["cert_signing"]

  subject {
    common_name         = var.dns_base_domain
    organization        = var.ssl_config["ssl_org"]
    organizational_unit = var.ssl_config["ssl_orgunit"]
    locality            = var.ssl_config["ssl_state"]
    province            = var.ssl_config["ssl_state"]
    country             = var.ssl_config["ssl_country"]
  }
}

output "root_ca_crt" {
  value = tls_self_signed_cert.root_ca.cert_pem
}

resource "aws_s3_object" "root_ca_crt" {
  bucket        = aws_s3_bucket.ma-certs.bucket
  key           = "ca/${var.pki_cn_name}.crt"
  content       = tls_self_signed_cert.root_ca.cert_pem
  kms_key_id    = aws_kms_key.pki.arn
  force_destroy = false
}

resource "aws_s3_object" "root_ca_key" {
  bucket        = aws_s3_bucket.ma-certs.bucket
  key           = "ca/${var.pki_cn_name}.key"
  content       = tls_private_key.root_ca.private_key_pem
  kms_key_id    = aws_kms_key.pki.arn
  force_destroy = false
}
