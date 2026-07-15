###############################################################################
# Slack alert SNS topic + Lambda — used for cluster ops alerts (CW alarms,
# cluster manager fixup state, SmartStore KMS DenyAccess, etc.).
###############################################################################

module "slack_alert" {
  source        = "../../modules/sns-slack-alert"
  name          = "splunk-ops-alert"
  slack_channel = var.slack_alerts_channel
  lambda_role   = lookup(local.roles["lambda-alert"], "arn")
}

# Telegram fan-out on the same topic. Populate the secret with:
#   aws secretsmanager put-secret-value --secret-id /monitoring/alerts/telegram \
#     --secret-string '{"bot_token":"<token>","chat_id":"<id>"}'
# The lambda no-ops gracefully until the secret is set.
module "telegram_alert" {
  source      = "../../modules/sns-telegram-alert"
  name        = "splunk-ops-alert"
  topic_arn   = module.slack_alert.sns_arn
  lambda_role = lookup(local.roles["lambda-alert"], "arn")
}
