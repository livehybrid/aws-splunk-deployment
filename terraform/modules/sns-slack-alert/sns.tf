resource "aws_sns_topic" "slack_alert" {
  count        = var.enabled
  name         = "${var.name}-slack-alert"
  display_name = "Slack alert for ${var.name}"
}

resource "aws_sns_topic_subscription" "slack_alert" {
  count     = var.enabled
  topic_arn = aws_sns_topic.slack_alert[count.index].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_alert[count.index].arn
}

