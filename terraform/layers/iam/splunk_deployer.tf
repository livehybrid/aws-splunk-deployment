###############################################################################
# Splunk SHC Deployer IAM role.
###############################################################################

resource "aws_iam_role" "splunk_deployer" {
  name                  = "SplunkDeployer"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_instance_profile" "splunk_deployer" {
  name = aws_iam_role.splunk_deployer.name
  role = aws_iam_role.splunk_deployer.name
}

resource "aws_iam_role_policy" "splunk_deployer" {
  name   = "splunk"
  role   = aws_iam_role.splunk_deployer.id
  policy = data.aws_iam_policy_document.splunk.json
}

resource "aws_iam_role_policy" "s3_ca_crt_access_deployer" {
  name   = "s3_ca_crt_access"
  role   = aws_iam_role.splunk_deployer.id
  policy = data.aws_iam_policy_document.s3_ca_crt_access.json
}

resource "aws_iam_role_policy" "ssm_access_deployer" {
  name   = "ssm_access"
  role   = aws_iam_role.splunk_deployer.id
  policy = data.aws_iam_policy_document.ssm_policy.json
}

resource "aws_iam_role_policy" "private_route53_deployer" {
  name   = "private_route53"
  role   = aws_iam_role.splunk_deployer.id
  policy = data.aws_iam_policy_document.private_route53.json
}

data "aws_iam_policy_document" "app_secrets_deployer" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/splunk/apps/*",
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/git/login*",
    ]
  }
}

resource "aws_iam_role_policy" "app_secrets_deployer" {
  name   = "deployer_secrets"
  role   = aws_iam_role.splunk_deployer.id
  policy = data.aws_iam_policy_document.app_secrets_deployer.json
}

resource "aws_iam_role_policy" "ec2_deployer_secretfile" {
  count  = var.enable_splunk_deployer
  name   = "secrets-file"
  role   = aws_iam_role.splunk_deployer.id
  policy = data.aws_iam_policy_document.splunk_secret_file.json
}
