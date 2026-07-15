resource "aws_lb" "splunk_heavy_forwarder" {
  name     = "splunk-heavy-forwarders"
  count    = local.enable_splunk_forwarder
  internal = false

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false # automated stop/start workflow destroys these nightly

  load_balancer_type = "network"

  subnets = values(local.net["default"])

  tags = {
    Name        = "splunk-heavy-forwarders"
    Environment = var.environment
    source      = "terraform"
    project     = "splunk"
  }
}


# Optional VPC Endpoint Service for cross-account ingestion. Off by default
# (set forwarder_consumer_principals in the workspace tfvars to enable).

resource "aws_vpc_endpoint_service" "splunk_heavy_forwarder" {
  count                      = local.enable_splunk_forwarder * (length(var.forwarder_consumer_principals) > 0 ? 1 : 0)
  acceptance_required        = true
  network_load_balancer_arns = [aws_lb.splunk_heavy_forwarder[0].arn]
  allowed_principals         = var.forwarder_consumer_principals
  depends_on                 = [aws_lb.splunk_heavy_forwarder]
  tags = {
    Name = "splunk-heavy-forwarder-endpoint"
  }
}

output "heavy_forwarder_service_endpoint" {
  value = aws_vpc_endpoint_service.splunk_heavy_forwarder.*.service_name
}

resource "aws_lb_listener" "splunk_heavy_forwarder" {
  count = local.enable_splunk_forwarder

  default_action {
    target_group_arn = aws_lb_target_group.splunk_heavy_forwarder[count.index].arn
    type             = "forward"
  }

  load_balancer_arn = aws_lb.splunk_heavy_forwarder[count.index].arn
  protocol          = "TCP"
  port              = 443
}

resource "aws_lb_target_group" "splunk_heavy_forwarder" {
  count                = local.enable_splunk_forwarder
  port                 = 9997
  protocol             = "TCP"
  deregistration_delay = 60
  vpc_id               = lookup(local.vpcs["default"], "id")
  name                 = "splunk-heavy-forwarders"

  stickiness {
    type    = "source_ip"
    enabled = false
  }
}

#Forwarder monitoring
resource "aws_cloudwatch_metric_alarm" "heavy-forwarder-rcvr" {
  count                     = local.enable_splunk_forwarder
  alarm_name                = "splunk-heavy-forwarder-rcvr"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = "1"
  metric_name               = "UnHealthyHostCount"
  namespace                 = "AWS/NetworkELB"
  period                    = "60"
  statistic                 = "Minimum"
  threshold                 = "0"
  alarm_description         = "Loadbalancer cannot reach one or more forwarders"
  insufficient_data_actions = []
  datapoints_to_alarm       = 1
  dimensions = {
    LoadBalancer = aws_lb.splunk_heavy_forwarder[count.index].arn_suffix
    TargetGroup  = aws_lb_target_group.splunk_heavy_forwarder[count.index].arn_suffix
  }
  alarm_actions = [lookup(local.sns["security-alerts"], "arn")]
}

