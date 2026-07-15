###############################################################################
# AWS Secrets Manager entries used by the Splunk cluster.
#
# - /pki/ca-password           : random password for the internal PKI CA.
# - /monitoring/splunk/license : Splunk Enterprise licence file (set manually).
# - /monitoring/alerts/slack_webhook : Slack webhook URL (set manually).
###############################################################################

resource "random_string" "ca-password" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "ca-password" {
  name       = "/pki/ca-password"
  kms_key_id = aws_kms_key.pki.id
}

resource "aws_secretsmanager_secret_version" "ca-password" {
  secret_id     = aws_secretsmanager_secret.ca-password.id
  secret_string = random_string.ca-password.result
}

resource "aws_secretsmanager_secret" "license" {
  name = "/monitoring/splunk/license"
}

resource "aws_secretsmanager_secret" "alerts_slack_webhook" {
  name = "/monitoring/alerts/slack_webhook"
}

resource "aws_secretsmanager_secret_version" "alerts_slack_webhook" {
  secret_id     = aws_secretsmanager_secret.alerts_slack_webhook.id
  secret_string = "UPDATE ME IN AWS CONSOLE"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Telegram alerting credentials: JSON {"bot_token": "...", "chat_id": "..."}.
# Value set manually (see sns.tf comment).
resource "aws_secretsmanager_secret" "alerts_telegram" {
  name = "/monitoring/alerts/telegram"
}
