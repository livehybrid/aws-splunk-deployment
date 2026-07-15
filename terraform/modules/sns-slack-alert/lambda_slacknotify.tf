data "archive_file" "slack_notify_zip" {
  type             = "zip"
  output_file_mode = var.zip_output_file_mode
  source_file      = "${path.module}/files/slack_notify.py"
  output_path      = "${path.module}/files/slack_notify.zip"
}

resource "aws_lambda_function" "slack_alert" {
  count            = var.enabled
  filename         = "${path.module}/files/slack_notify.zip"
  function_name    = "${var.name}_slack_alert"
  role             = var.lambda_role
  handler          = "slack_notify.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  source_code_hash = data.archive_file.slack_notify_zip.output_base64sha256

  depends_on = [data.archive_file.slack_notify_zip]

  environment {
    variables = {
      slack_channel    = var.slack_channel
      token_secretpath = "/monitoring/alerts/${var.name}_token"
      account_name     = local.account_name
    }
  }
}

resource "aws_lambda_permission" "from_sns" {
  count         = var.enabled
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_alert[count.index].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.slack_alert[count.index].arn
}