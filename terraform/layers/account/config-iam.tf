###############################################################################
# Cross-service IAM roles used by the account layer's own resources
# (AWS Config, CloudTrail→CloudWatch, slack-alert Lambda).
###############################################################################

###############################################################################
# CloudTrail → CloudWatch Logs.
###############################################################################

resource "aws_iam_role" "cloudtrail" {
  name = "cloudtrail-to-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "cloudtrail.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail" {
  name = "cloudtrail"
  role = aws_iam_role.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AWSCloudTrailCreateLogStream"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream"]
        Resource = ["${aws_cloudwatch_log_group.cloudtrail.arn}*"]
      },
      {
        Sid      = "AWSCloudTrailPutLogEvents"
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.cloudtrail.arn}*"]
      },
    ]
  })
}

###############################################################################
# slack-alert Lambda — invoked by SNS for ops alerts.
###############################################################################

resource "aws_iam_role" "lambda" {
  name = "sns-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda-slack-policy" {
  name = "lambda-cloudwatch-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents", "logs:CreateLogStream", "logs:CreateLogGroup"]
        Resource = ["arn:aws:logs:*:*:*"]
      },
      {
        Sid    = "AllowAccessToWebHookSecretsManager"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          local.secrets["slack-webook"]["arn"],
          "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:/monitoring/alerts/*",
        ]
      },
    ]
  })
}
