###############################################################################
# Splunk Monitoring Console IAM role.
###############################################################################

resource "aws_iam_role" "splunk_mc" {
  name                  = "SplunkMonitoringConsole"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_instance_profile" "splunk_mc" {
  name = aws_iam_role.splunk_mc.name
  role = aws_iam_role.splunk_mc.name
}

resource "aws_iam_role_policy" "splunk_mc" {
  name   = "splunk"
  role   = aws_iam_role.splunk_mc.id
  policy = data.aws_iam_policy_document.splunk.json
}

resource "aws_iam_role_policy" "s3_ca_crt_access_mc" {
  name   = "s3_ca_crt_access"
  role   = aws_iam_role.splunk_mc.id
  policy = data.aws_iam_policy_document.s3_ca_crt_access.json
}

resource "aws_iam_role_policy" "ssm_access_mc" {
  name   = "ssm_access"
  role   = aws_iam_role.splunk_mc.id
  policy = data.aws_iam_policy_document.ssm_policy.json
}

resource "aws_iam_role_policy" "private_route53_mc" {
  name   = "private_route53"
  role   = aws_iam_role.splunk_mc.id
  policy = data.aws_iam_policy_document.private_route53.json
}

# MC publishes cluster health metrics back to CloudWatch (alarms in account layer
# can fan out to ops Slack).
data "aws_iam_policy_document" "cw_put_metric_mc" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cw_put_metric_mc" {
  name   = "cw_put_metric"
  role   = aws_iam_role.splunk_mc.id
  policy = data.aws_iam_policy_document.cw_put_metric_mc.json
}

resource "aws_iam_role_policy" "ec2_mc_secretfile" {
  count  = var.enable_splunk_monitoring_console
  name   = "secrets-file"
  role   = aws_iam_role.splunk_mc.id
  policy = data.aws_iam_policy_document.splunk_secret_file.json
}
