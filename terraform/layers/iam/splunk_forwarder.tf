resource "aws_iam_role_policy" "splunk_forwarder" {
  name   = "splunk"
  role   = aws_iam_role.splunk_forwarder.id
  policy = data.aws_iam_policy_document.splunk.json
}

resource "aws_iam_instance_profile" "splunk_forwarder" {
  name = aws_iam_role.splunk_forwarder.name
  role = aws_iam_role.splunk_forwarder.name
}

resource "aws_iam_role" "splunk_forwarder" {
  name                  = "SplunkForwarder"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy" "s3_ca_crt_access_fwd" {
  name   = "s3_ca_crt_access"
  role   = aws_iam_role.splunk_forwarder.id
  policy = data.aws_iam_policy_document.s3_ca_crt_access.json
}

resource "aws_iam_role_policy" "ssm_access_fwd" {
  name   = "ssm_access"
  role   = aws_iam_role.splunk_forwarder.id
  policy = data.aws_iam_policy_document.ssm_policy.json
}

resource "aws_iam_role_policy" "private_route53_fwd" {
  name   = "private_route53"
  role   = aws_iam_role.splunk_forwarder.id
  policy = data.aws_iam_policy_document.private_route53.json
}

#Cannot be locked to specific eips
data "aws_iam_policy_document" "ec2_associate_fwd_eip" {
  statement {
    actions = [
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:DescribeAddresses",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_associate_fwd_eip" {
  count = var.enable_splunk_forwarder

  name   = "associate_eip"
  role   = aws_iam_role.splunk_forwarder.id
  policy = data.aws_iam_policy_document.ec2_associate_fwd_eip.json
}

resource "aws_iam_role_policy" "fwd-sns-security-alert" {
  count = var.enable_splunk_forwarder

  name   = "sns-security-alert"
  role   = aws_iam_role.splunk_forwarder.id
  policy = data.aws_iam_policy_document.sns-security-alert.json
}


resource "aws_iam_role_policy" "ec2_forwarder_secretfile" {
  count = var.enable_splunk_forwarder

  name   = "secrets-file"
  policy = data.aws_iam_policy_document.splunk_secret_file.json
  role   = aws_iam_role.splunk_forwarder.id
}
