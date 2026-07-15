###############################################################################
# Telegram subscriber for an existing SNS alert topic.
# Credentials live in Secrets Manager (JSON {"bot_token","chat_id"}); the
# handler no-ops gracefully while the secret is unpopulated.
###############################################################################

variable "name" {}
variable "topic_arn" { description = "Existing SNS topic to subscribe to." }
variable "lambda_role" { description = "IAM role ARN (needs /monitoring/alerts/* secret read)." }
variable "telegram_secretpath" { default = "/monitoring/alerts/telegram" }

data "archive_file" "telegram_notify_zip" {
  type        = "zip"
  source_file = "${path.module}/files/telegram_notify.py"
  output_path = "${path.module}/files/telegram_notify.zip"
}

data "aws_caller_identity" "current" {}

resource "aws_lambda_function" "telegram_alert" {
  filename         = data.archive_file.telegram_notify_zip.output_path
  function_name    = "${var.name}_telegram_alert"
  role             = var.lambda_role
  handler          = "telegram_notify.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 30
  source_code_hash = data.archive_file.telegram_notify_zip.output_base64sha256

  environment {
    variables = {
      telegram_secretpath = var.telegram_secretpath
      account_name        = data.aws_caller_identity.current.account_id
    }
  }
}

resource "aws_lambda_permission" "from_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.telegram_alert.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.topic_arn
}

resource "aws_sns_topic_subscription" "telegram_alert" {
  topic_arn = var.topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.telegram_alert.arn
}

output "function_name" {
  value = aws_lambda_function.telegram_alert.function_name
}
