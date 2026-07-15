resource "aws_iam_role_policy" "splunk_license" {
  name   = "splunk"
  role   = aws_iam_role.splunk_license.id
  policy = data.aws_iam_policy_document.splunk.json
}

resource "aws_iam_instance_profile" "splunk_license" {
  name = aws_iam_role.splunk_license.name
  role = aws_iam_role.splunk_license.name
}

resource "aws_iam_role" "splunk_license" {
  name                  = "SplunkLicense"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy" "s3_ca_crt_access_license" {
  name   = "s3_ca_crt_access"
  role   = aws_iam_role.splunk_license.id
  policy = data.aws_iam_policy_document.s3_ca_crt_access.json
}

resource "aws_iam_role_policy" "ssm_access_lic" {
  name   = "ssm_access"
  role   = aws_iam_role.splunk_license.id
  policy = data.aws_iam_policy_document.ssm_policy.json
}

#Cannot be locked to specific eips
data "aws_iam_policy_document" "ec2_associate_license_eip" {
  statement {
    actions = [
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:DescribeAddresses",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_associate_license_eip" {
  count = var.enable_splunk_license

  name   = "associate_eip"
  role   = aws_iam_role.splunk_license.id
  policy = data.aws_iam_policy_document.ec2_associate_license_eip.json
}

#Allow license to get license

data "aws_iam_policy_document" "splunk_secret_license" {
  statement {
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
    ]

    resources = [
      lookup(local.secrets["license"], "arn"),
    ]
  }
}

#Allow license to associate elastic IP
resource "aws_iam_role_policy" "splunk_license_license" {
  count = var.enable_splunk_license

  name   = "secret_license"
  role   = aws_iam_role.splunk_license.id
  policy = data.aws_iam_policy_document.splunk_secret_license.json
}

resource "aws_iam_role_policy" "ec2_license_secretfile" {
  count = var.enable_splunk_license

  name   = "secrets-file"
  policy = data.aws_iam_policy_document.splunk_secret_file.json
  role   = aws_iam_role.splunk_license.id
}
