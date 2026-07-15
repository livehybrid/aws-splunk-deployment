# -----------------------------------------------------------
# setup audit filters
# -----------------------------------------------------------

# ----------------------
# watch for use of the root account
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "root_login" {
  name           = "root-access"
  pattern        = "{$.userIdentity.type = Root}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "RootAccessCount"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_login" {
  alarm_name          = "root-access-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "RootAccessCount"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Use of the root account has been detected"
  alarm_actions       = [module.slack_alert.sns_arn]
}

# ----------------------
# watch for use of the console without MFA
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "console_without_mfa" {
  name           = "console-without-mfa"
  pattern        = "{$.eventName = ConsoleLogin && $.additionalEventData.MFAUsed = No}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "ConsoleWithoutMFACount"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "console_without_mfa" {
  alarm_name          = "console-without-mfa-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "ConsoleWithoutMFACount"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Use of the console by an account without MFA has been detected"
  alarm_actions       = [module.slack_alert.sns_arn]
}

# ----------------------
# watch for actions triggered by accounts without MFA
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "action_without_mfa" {
  name           = "action-without-mfa"
  pattern        = "{$.userIdentity.type != AssumedRole && $.userIdentity.sessionContext.attributes.mfaAuthenticated != true}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "UserWithoutMFACount"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "action_without_mfa" {
  alarm_name          = "action-without-mfa-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "UserWithoutMFACount"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Actions triggered by a user account without MFA has been detected"
  alarm_actions       = [module.slack_alert.sns_arn]
}

# ----------------------
# look for key alias changes or key deletions
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "illegal_key_use" {
  name           = "key-changes"
  pattern        = "{$.eventSource = kms.amazonaws.com && ($.eventName = DeleteAlias || $.eventName = DisableKey)}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "KeyChangeOrDelete"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "illegal_key_use" {
  alarm_name          = "key-changes-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "KeyChangeOrDelete"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "A key alias has been changed or a key has been deleted"
  alarm_actions       = [module.slack_alert.sns_arn]
}

# ----------------------
# look for use of KMS keys by users
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "decription_with_key" {
  name           = "decription_with_key"
  pattern        = "{($.userIdentity.type = IAMUser || $.userIdentity.type = AssumeRole) && $.eventSource = kms.amazonaws.com && $.eventName = Decrypt}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "DecryptionWithKMS"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

# ----------------------
# look for changes to security groups
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "security_group_change" {
  name           = "security-group-changes"
  pattern        = "{ $.eventName = AuthorizeSecurityGroup* || $.eventName = RevokeSecurityGroup* || $.eventName = CreateSecurityGroup || $.eventName = DeleteSecurityGroup }"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "SecurityGroupChanges"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "security_group_change" {
  alarm_name          = "security-group-changes-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "SecurityGroupChanges"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Security groups have been changed"
  alarm_actions       = [module.slack_alert.sns_arn]
}

# ----------------------
# look for changes to IAM resources
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "iam_change" {
  name           = "iam-changes"
  pattern        = "{$.eventSource = iam.* && $.eventName != Get* && $.eventName != List* && $.eventName!= GenerateCredentialReport}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "IamChanges"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_change" {
  alarm_name          = "iam-changes-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "IamChanges"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "IAM Resources have been changed"
  alarm_actions       = [module.slack_alert.sns_arn]
}

# ----------------------
# look for changes to route table resources
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "routetable_change" {
  name           = "route-table-changes"
  pattern        = "{$.eventSource = ec2.* && ($.eventName = AssociateRouteTable || $.eventName = CreateRoute* || $.eventName = CreateVpnConnectionRoute || $.eventName = DeleteRoute* || $.eventName = DeleteVpnConnectionRoute || $.eventName = DisableVgwRoutePropagation || $.eventName = DisassociateRouteTable || $.eventName = EnableVgwRoutePropagation || $.eventName = ReplaceRoute*)}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "RouteTableChanges"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "routetable_change" {
  alarm_name          = "route-table-changes-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "RouteTableChanges"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Route Table Resources have been changed"
  alarm_actions       = [module.slack_alert.sns_arn]
}

# ----------------------
# look for changes to NACL
# ----------------------
resource "aws_cloudwatch_log_metric_filter" "nacl_change" {
  name           = "nacl-changes"
  pattern        = "{$.eventSource = ec2.* && ($.eventName = CreateNetworkAcl* || $.eventName = DeleteNetworkAcl* || $.eventName = ReplaceNetworkAcl*)}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name      = "NaclChanges"
    namespace = local.cloudtrail_metric_name_space
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "nacl_change" {
  alarm_name          = "nacl-changes-${var.region}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "NaclChanges"
  namespace           = local.cloudtrail_metric_name_space
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "NACL have been changed"
  alarm_actions       = [module.slack_alert.sns_arn]
}

#nacl
