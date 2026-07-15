resource "aws_lb" "splunk_license" {
  name     = "splunk-license-ha"
  count    = local.enable_splunk_license
  internal = true

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false # automated stop/start workflow destroys these nightly

  load_balancer_type = "network"

  subnets = values(local.net["default"])

  tags = {
    Name        = "splunk-license-ha"
    Environment = var.environment
    source      = "terraform"
    project     = "splunk"
  }
}

#Service Endpoint for License server

resource "aws_vpc_endpoint_service" "splunk_license" {
  count               = local.enable_splunk_license
  acceptance_required = false
  network_load_balancer_arns = [
  aws_lb.splunk_license[count.index].arn]
  allowed_principals = ["*"]
  depends_on         = [aws_lb.splunk_license]
  tags = {
    Name = "license"
  }
}

output "license_service_endpoint" {
  value = aws_vpc_endpoint_service.splunk_license.*.service_name
}

resource "aws_lb_listener" "splunk_license" {
  count = local.enable_splunk_license

  default_action {
    target_group_arn = aws_lb_target_group.splunk_license[count.index].arn
    type             = "forward"
  }

  load_balancer_arn = aws_lb.splunk_license[count.index].arn
  protocol          = "TCP"
  port              = 443
}

# Listener accepts 443 (endpoint-service consumers) and forwards to splunkd
# management on 8089 — the licence-peer API. TG port 443 was a bug: nothing
# listens there, so the NLB health check could never pass.
resource "aws_lb_target_group" "splunk_license" {
  count                = local.enable_splunk_license
  port                 = 8089
  protocol             = "TCP"
  vpc_id               = lookup(local.vpcs["default"], "id")
  name                 = "splunk-license-ha"
  deregistration_delay = 60

  stickiness {
    type    = "source_ip"
    enabled = false
  }
}
