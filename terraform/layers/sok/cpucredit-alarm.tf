###############################################################################
# NFR-2: CPU-credit-balance alarm for the burstable SOK nodes.
#
# The SOK node groups run on burstable t3 instances (dev: t3.xlarge, prod:
# t3.large, deliberately small for the build-out test). Burstable instances
# earn CPU credits at a baseline rate and spend them to burst above baseline;
# once CPUCreditBalance hits zero they are throttled to baseline (Unlimited
# mode instead bills for surplus credits). For splunkd this surfaces as sudden,
# hard-to-diagnose slowness. Alarm before the balance runs out.
#
# --- Why per-instance metric math, and its limitation ---
# AWS/EC2 CPUCreditBalance is published ONLY per instance (dimension
# InstanceId). It has no AutoScalingGroupName dimension, and a CloudWatch SEARCH
# SearchTerm matches tokens from the metric SCHEMA (namespace / metric name /
# dimension names+values), NOT from EC2 tags or ASG membership, so an ASG name
# cannot scope this metric via SEARCH. The rebuild-stable, correctly-scoped
# approach is therefore to resolve the ASG's current instance IDs (data source
# below) and build a metric-math alarm that takes the MIN of CPUCreditBalance
# across exactly those instances: the alarm fires when the WORST node in the
# group is low.
#
# This layer re-applies on every nightly rebuild (it rebuilds with the
# nodegroup), so the instance IDs are re-resolved each rebuild and the alarm
# always tracks the live instances. LIMITATION: a scale-up that adds an instance
# BETWEEN applies is not covered until the next apply (dev/prod both run desired
# == min today, so scale-out is rare); if that changes, move to an Unlimited-mode
# surplus-credit posture or a per-instance auto-alarm Lambda. INSUFFICIENT_DATA
# (e.g. a group briefly at zero instances) is treated as notBreaching.
###############################################################################

locals {
  node_asg_names = data.terraform_remote_state.eks.outputs.node_group_autoscaling_group_names
}

# Current instance IDs per ASG (re-resolved each apply, see header). The
# aws_autoscaling_group data source does NOT expose instance IDs, so resolve them
# with aws_instances filtered on the ASG's auto-propagated groupName tag.
data "aws_instances" "sok_nodes" {
  for_each             = toset(local.node_asg_names)
  instance_state_names = ["running"]
  instance_tags = {
    "aws:autoscaling:groupName" = each.value
  }
}

# SNS topic the alarm publishes to. The estate's only other alerting path is the
# in-cluster Slack watchdog (alerting.tf), which reads a webhook at RUN time and
# so cannot be a CloudWatch alarm action; an SNS topic is the native target.
# Attach a destination with sok_alarm_notify_email (email) or subscribe a Lambda
# / AWS Chatbot to bridge to Slack out of band.
resource "aws_sns_topic" "sok_alarms" {
  name = "splunk-sok-${var.environment}-alarms"
}

resource "aws_sns_topic_subscription" "sok_alarms_email" {
  count     = var.sok_alarm_notify_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.sok_alarms.arn
  protocol  = "email"
  endpoint  = var.sok_alarm_notify_email
}

resource "aws_cloudwatch_metric_alarm" "node_cpucredit_low" {
  # One alarm per ASG that currently has instances (an empty group has no metric
  # math to build; it gets an alarm again once nodes join on the next apply).
  for_each = {
    for name, insts in data.aws_instances.sok_nodes :
    name => insts.ids if length(insts.ids) > 0
  }

  alarm_name        = "splunk-sok-${var.environment}-cpucredit-low-${each.key}"
  alarm_description = "A burstable node in ASG ${each.key} is low on CPU credits (min CPUCreditBalance < ${var.sok_cpucredit_low_threshold}). Sustained burst will throttle splunkd to baseline (NFR-2)."

  comparison_operator = "LessThanThreshold"
  threshold           = var.sok_cpucredit_low_threshold
  evaluation_periods  = 3 # 3 consecutive 5-min periods -> ride out brief dips
  treat_missing_data  = "notBreaching"

  # One CPUCreditBalance metric per current instance, then MIN across them so the
  # alarm reflects the worst node in the group.
  dynamic "metric_query" {
    for_each = each.value
    content {
      id = "m${metric_query.key}"
      metric {
        namespace   = "AWS/EC2"
        metric_name = "CPUCreditBalance"
        dimensions  = { InstanceId = metric_query.value }
        period      = 300
        stat        = "Average"
      }
      return_data = false
    }
  }

  metric_query {
    id          = "cpucredit_min"
    expression  = "MIN([${join(",", [for i in range(length(each.value)) : "m${i}"])}])"
    label       = "Min CPUCreditBalance across ${each.key}"
    return_data = true
  }

  alarm_actions             = [aws_sns_topic.sok_alarms.arn]
  ok_actions                = [aws_sns_topic.sok_alarms.arn]
  insufficient_data_actions = []

  tags = {
    "splunk.livehybrid.com/deployment-model" = "sok"
  }
}
