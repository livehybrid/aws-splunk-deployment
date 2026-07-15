###############################################################################
# ASG lifecycle + Spot interruption events → Splunk HEC.
#
# EventBridge API destination POSTs directly to the HEC endpoint behind the
# splunk-web ALB — no Lambda. The HEC token is generated here, stored in
# Secrets Manager, and the heavy-forwarder bootstrap renders it into an
# [http://aws-events] input at boot (useACK off: API destinations can't do
# ACK channels). Searchable as sourcetype=aws:events in index=main.
###############################################################################

resource "random_uuid" "hec_aws_events_token" {}

resource "aws_secretsmanager_secret" "hec_aws_events" {
  name = "/splunk/hec/aws-events"
}

resource "aws_secretsmanager_secret_version" "hec_aws_events" {
  secret_id     = aws_secretsmanager_secret.hec_aws_events.id
  secret_string = random_uuid.hec_aws_events_token.result
}

resource "aws_cloudwatch_event_connection" "splunk_hec" {
  count              = local.enable_splunk_forwarder
  name               = "splunk-hec-${var.environment}"
  description        = "Auth header for Splunk HEC"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "Authorization"
      value = "Splunk ${random_uuid.hec_aws_events_token.result}"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "splunk_hec" {
  count                            = local.enable_splunk_forwarder
  name                             = "splunk-hec-${var.environment}"
  connection_arn                   = aws_cloudwatch_event_connection.splunk_hec[0].arn
  http_method                      = "POST"
  invocation_endpoint              = "https://hec.${lookup(local.dns["public-splunk"], "name")}/services/collector/event"
  invocation_rate_limit_per_second = 10
}

resource "aws_cloudwatch_event_rule" "asg_lifecycle" {
  name        = "splunk-${var.environment}-asg-lifecycle"
  description = "ASG launches/terminations + spot interruption/rebalance to Splunk"

  event_pattern = jsonencode({
    "source" : ["aws.autoscaling", "aws.ec2"],
    "detail-type" : [
      "EC2 Instance Launch Successful",
      "EC2 Instance Launch Unsuccessful",
      "EC2 Instance Terminate Successful",
      "EC2 Instance Terminate Unsuccessful",
      "EC2 Spot Instance Interruption Warning",
      "EC2 Instance Rebalance Recommendation",
    ]
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

# Count-gated: under the shutdown overlay the API destination doesn't exist,
# and an ungated data source would fail evaluation with "Invalid index".
data "aws_iam_policy_document" "events_invoke_hec" {
  count = local.enable_splunk_forwarder
  statement {
    actions   = ["events:InvokeApiDestination"]
    resources = [aws_cloudwatch_event_api_destination.splunk_hec[0].arn]
  }
}

resource "aws_iam_role" "events_to_hec" {
  count              = local.enable_splunk_forwarder
  name               = "splunk-${var.environment}-events-to-hec"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "events_to_hec" {
  count  = local.enable_splunk_forwarder
  role   = aws_iam_role.events_to_hec[0].id
  policy = data.aws_iam_policy_document.events_invoke_hec[0].json
}

resource "aws_cloudwatch_event_target" "asg_to_hec" {
  count    = local.enable_splunk_forwarder
  rule     = aws_cloudwatch_event_rule.asg_lifecycle.name
  arn      = aws_cloudwatch_event_api_destination.splunk_hec[0].arn
  role_arn = aws_iam_role.events_to_hec[0].arn

  # Wrap the raw event in a HEC envelope.
  input_transformer {
    input_paths = {
      account = "$.account"
      region  = "$.region"
      dtype   = "$.detail-type"
      time    = "$.time"
      detail  = "$.detail"
    }
    input_template = <<-EOT
      {"sourcetype": "aws:events", "source": "eventbridge", "event": {"detail-type": <dtype>, "account": <account>, "region": <region>, "time": <time>, "detail": <detail>}}
    EOT
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}
