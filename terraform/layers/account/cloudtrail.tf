resource "aws_cloudwatch_log_group" "cloudtrail" {
  name = "cloudtrail"

  #Not done here...
  //kms_key_id        = "${lookup(local.kms["cloudtrail"], "arn")}"
  retention_in_days = 30

  tags = {
    Name    = "cloudwatch_logs"
    source  = "terraform"
    project = "splunk"
  }
}

