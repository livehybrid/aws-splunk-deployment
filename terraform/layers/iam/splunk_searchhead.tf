resource "aws_iam_role_policy" "splunk_sh" {
  count  = var.enable_splunk_searchhead
  name   = "SplunkSearchhead"
  role   = aws_iam_role.splunk_sh[count.index].id
  policy = data.aws_iam_policy_document.splunk.json
}

resource "aws_iam_instance_profile" "splunk_sh" {
  count = var.enable_splunk_searchhead
  name  = aws_iam_role.splunk_sh[count.index].name
  role  = aws_iam_role.splunk_sh[count.index].name
}
#Used to send SNS alerts from Splunk
resource "aws_iam_role_policy" "sns-security-alert_sh" {
  count  = var.enable_splunk_searchhead
  name   = "sns-security-alert"
  role   = aws_iam_role.splunk_sh[count.index].id
  policy = data.aws_iam_policy_document.sns-security-alert.json
}

resource "aws_iam_role" "splunk_sh" {
  count                 = var.enable_splunk_searchhead
  name                  = "SplunkSearchhead"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

//data "aws_iam_policy_document" "splunk_sh_secrets" {
//  statement {
//    actions = [
//      "secretsmanager:GetSecretValue"
//    ]
//    resources = [
//      "${aws_secretsmanager_secret.sh_crt.arn}",
//      "${aws_secretsmanager_secret.sh_key.arn}",
//    ]
//  }
//}

//resource "aws_iam_role_policy" "splunk_sh_secrets" {
//  name   = "sh-secrets"
//  role   = "${aws_iam_role.splunk_sh.id}"
//  policy = "${data.aws_iam_policy_document.splunk_sh_secrets.json}"
//}

resource "aws_iam_role_policy" "s3_ca_crt_access_sh" {
  count  = var.enable_splunk_searchhead
  name   = "s3_ca_crt_access"
  role   = aws_iam_role.splunk_sh[count.index].id
  policy = data.aws_iam_policy_document.s3_ca_crt_access.json
}
resource "aws_iam_role_policy" "ssm_access_sh" {
  count  = var.enable_splunk_searchhead
  name   = "ssm_access"
  role   = aws_iam_role.splunk_sh[count.index].id
  policy = data.aws_iam_policy_document.ssm_policy.json
}

resource "aws_iam_role_policy" "private_route53_sh" {
  count  = var.enable_splunk_searchhead
  name   = "private_route53"
  role   = aws_iam_role.splunk_sh[count.index].id
  policy = data.aws_iam_policy_document.private_route53.json
}

resource "aws_iam_role_policy" "ec2_sh_secretfile" {
  count  = var.enable_splunk_searchhead
  name   = "secrets-file"
  policy = data.aws_iam_policy_document.splunk_secret_file.json
  role   = aws_iam_role.splunk_sh[count.index].id
}
