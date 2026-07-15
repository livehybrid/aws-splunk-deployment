###############################################################################
# Splunk Cluster Manager IAM role.
###############################################################################

resource "aws_iam_role" "splunk_manager" {
  name                  = "SplunkManager"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_instance_profile" "splunk_manager" {
  name = aws_iam_role.splunk_manager.name
  role = aws_iam_role.splunk_manager.name
}

resource "aws_iam_role_policy" "splunk_manager" {
  name   = "splunk"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.splunk.json
}

resource "aws_iam_role_policy" "s3_ca_crt_access_manager" {
  name   = "s3_ca_crt_access"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.s3_ca_crt_access.json
}

data "aws_iam_policy_document" "public_route53_manager" {
  statement {
    actions = ["route53:ChangeResourceRecordSets"]
    resources = [
      "arn:aws:route53:::hostedzone/${lookup(local.dns["public-splunk"], "zone_id")}",
    ]
  }
}

resource "aws_iam_role_policy" "public_route53_manager" {
  name   = "public_route53"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.public_route53_manager.json
}

resource "aws_iam_role_policy" "private_route53_manager" {
  name   = "private_route53"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.private_route53.json
}

data "aws_iam_policy_document" "app_secrets_manager" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/splunk/apps/*",
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/git/login*",
    ]
  }
}

resource "aws_iam_role_policy" "app_secrets_manager" {
  name   = "manager_secrets"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.app_secrets_manager.json
}

resource "aws_iam_role_policy" "ssm_access_manager" {
  name   = "ssm_access"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.ssm_policy.json
}

# Cannot be locked to specific EIPs.
data "aws_iam_policy_document" "ec2_associate_manager_eip" {
  statement {
    actions = [
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:DescribeAddresses",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_associate_manager_eip" {
  count  = var.enable_splunk_manager
  name   = "associate_eip"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.ec2_associate_manager_eip.json
}

resource "aws_iam_role_policy" "ec2_manager_secretfile" {
  count  = var.enable_splunk_manager
  name   = "secrets-file"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.splunk_secret_file.json
}

# Admin-password rotation (make rotate-admin): the manager generates the new
# value and writes it back; peers only ever read.
data "aws_iam_policy_document" "manager_rotate_admin_secret" {
  statement {
    actions   = ["secretsmanager:PutSecretValue"]
    resources = ["arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/monitoring/splunk/password*"]
  }
}

resource "aws_iam_role_policy" "manager_rotate_admin_secret" {
  name   = "rotate-admin-secret"
  role   = aws_iam_role.splunk_manager.id
  policy = data.aws_iam_policy_document.manager_rotate_admin_secret.json
}
