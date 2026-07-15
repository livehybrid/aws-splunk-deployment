###############################################################################
# Internal-CA certificate issuer Lambda.
#
# cryptography ships C extensions, so the deps are pip-installed for the
# Lambda target platform (manylinux aarch64 / cp3.13) into build/stage at
# apply time, then zipped. Requires python3 + pip on the machine running
# terraform apply.
###############################################################################

variable "name" {}
variable "ca_bucket" {}
variable "ca_key_object" {}
variable "ca_crt_object" {}
variable "kms_key_arn" {}
variable "allowed_dns_suffixes" { description = "Comma-separated DNS suffixes the issuer will sign for." }
variable "validity_days" { default = 730 }

resource "null_resource" "build" {
  triggers = {
    handler      = filesha256("${path.module}/files/cert_issuer.py")
    requirements = filesha256("${path.module}/files/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      rm -rf '${path.module}/build/stage'
      mkdir -p '${path.module}/build/stage'
      python3 -m pip install --quiet --target '${path.module}/build/stage' \
        --platform manylinux2014_aarch64 --implementation cp \
        --python-version 3.13 --only-binary=:all: \
        -r '${path.module}/files/requirements.txt'
      cp '${path.module}/files/cert_issuer.py' '${path.module}/build/stage/'
    EOT
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/build/stage"
  output_path = "${path.module}/build/cert_issuer.zip"

  depends_on = [null_resource.build]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "permissions" {
  statement {
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.ca_bucket}/${var.ca_key_object}",
      "arn:aws:s3:::${var.ca_bucket}/${var.ca_crt_object}",
    ]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role" "cert_issuer" {
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "cert_issuer" {
  name   = "cert-issuer"
  role   = aws_iam_role.cert_issuer.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_lambda_function" "cert_issuer" {
  function_name    = var.name
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.cert_issuer.arn
  handler          = "cert_issuer.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      CA_BUCKET            = var.ca_bucket
      CA_KEY_OBJECT        = var.ca_key_object
      CA_CRT_OBJECT        = var.ca_crt_object
      ALLOWED_DNS_SUFFIXES = var.allowed_dns_suffixes
      VALIDITY_DAYS        = var.validity_days
    }
  }
}

output "function_name" {
  value = aws_lambda_function.cert_issuer.function_name
}

output "function_arn" {
  value = aws_lambda_function.cert_issuer.arn
}
