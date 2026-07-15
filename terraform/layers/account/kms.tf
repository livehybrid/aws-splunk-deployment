###############################################################################
# KMS keys for the LiveHybrid Splunk C3 deployment.
#
# - pki:              PKI bucket + cluster-internal CA encryption.
# - checkpoints:      Heavy Forwarder checkpoint bucket encryption.
# - splunk-smartstore: SmartStore warm/cold bucket encryption.
###############################################################################

resource "aws_kms_key" "pki" {
  deletion_window_in_days = 7
  description             = "PKI Encryption Key"
  enable_key_rotation     = true

  tags = {
    Name    = "pki-key"
    source  = "terraform"
    project = "splunk"
  }

  lifecycle {
    prevent_destroy = true
  }

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": { "AWS": ["arn:aws:iam::${local.account_id}:root"] },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow Lambda to Access",
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_kms_alias" "pki" {
  name          = "alias/pki-key"
  target_key_id = aws_kms_key.pki.id
}

resource "aws_kms_key" "checkpoints" {
  deletion_window_in_days = 7
  description             = "Splunk checkpoints bucket encryption key"
  enable_key_rotation     = true

  tags = {
    Name    = "splunk-checkpoints-key"
    source  = "terraform"
    project = "splunk"
  }

  lifecycle {
    prevent_destroy = true
  }

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": { "AWS": ["arn:aws:iam::${local.account_id}:root"] },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_kms_alias" "checkpoints" {
  name          = "alias/splunk-checkpoints-key"
  target_key_id = aws_kms_key.checkpoints.id
}

resource "aws_kms_key" "splunk-smartstore" {
  count                   = var.enable_smartstore
  deletion_window_in_days = 7
  description             = "Splunk SmartStore (${var.environment}) bucket encryption key"
  enable_key_rotation     = true

  tags = {
    Name        = "splunk-smartstore-${var.environment}-key"
    source      = "terraform"
    project     = "splunk"
    Environment = var.environment
  }

  lifecycle {
    prevent_destroy = true
  }

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": { "AWS": ["arn:aws:iam::${local.account_id}:root"] },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_kms_alias" "splunk-smartstore" {
  count         = var.enable_smartstore
  name          = "alias/splunk-smartstore-${var.environment}-key"
  target_key_id = aws_kms_key.splunk-smartstore[0].id
}
