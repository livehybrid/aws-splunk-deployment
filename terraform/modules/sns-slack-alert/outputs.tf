output "name" {
  value = var.enabled == 1 ? aws_sns_topic.slack_alert[0].name : ""
}

output "id" {
  value = var.enabled == 1 ? aws_sns_topic.slack_alert[0].id : ""
}

output "sns_arn" {
  value = var.enabled == 1 ? aws_sns_topic.slack_alert[0].arn : ""
}