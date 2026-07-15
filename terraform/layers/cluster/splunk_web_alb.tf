###############################################################################
# Consolidated Splunk Web ALB.
#
# One ALB serves every HTTPS Splunk Web endpoint via host-based routing:
#   manager.<domain>  → splunk_manager_ui   (port 8000)
#   license.<domain>  → splunk_license_ui   (port 8000)
#   mc.<domain>       → splunk_mc_ui        (port 8000)
#   search.<domain>   → splunk_searchheads  (port 8000)
#   hec.<domain>      → splunk_forwarder_hec (port 8088)
#
# Wildcard ACM cert (*.<domain>) covers all five subdomains; new roles only
# need a new TG + listener rule + R53 record.
###############################################################################

locals {
  splunk_web_enabled = local.enable_splunk_manager + local.enable_splunk_license + local.enable_splunk_searchhead + local.enable_splunk_forwarder > 0 ? 1 : 0
  splunk_public_dns  = lookup(local.dns["public-splunk"], "name")
}

############################# Wildcard ACM cert ##############################
# Deliberately NOT gated on the role-enable counts: ACM certs are free, and
# keeping the cert (+ validation record) through the overnight shutdown
# overlay avoids re-issuing/re-validating on every start/stop cycle.

resource "aws_acm_certificate" "splunk_web" {
  count             = 1
  domain_name       = "*.${local.splunk_public_dns}"
  validation_method = "DNS"

  tags = {
    Name        = "splunk-web"
    Environment = var.environment
    source      = "terraform"
    project     = "splunk"
  }
}

resource "aws_route53_record" "splunk_web_acm_validation" {
  count   = 1
  zone_id = lookup(local.dns["public-splunk"], "zone_id")

  name = tolist(aws_acm_certificate.splunk_web[count.index].domain_validation_options)[0].resource_record_name
  type = tolist(aws_acm_certificate.splunk_web[count.index].domain_validation_options)[0].resource_record_type
  records = [
    tolist(aws_acm_certificate.splunk_web[count.index].domain_validation_options)[0].resource_record_value,
  ]
  ttl = 60
}

resource "aws_acm_certificate_validation" "splunk_web" {
  count                   = 1
  certificate_arn         = aws_acm_certificate.splunk_web[count.index].arn
  validation_record_fqdns = [aws_route53_record.splunk_web_acm_validation[count.index].fqdn]
}

############################# The ALB itself #################################

resource "aws_lb" "splunk_web" {
  count = local.splunk_web_enabled
  name  = "splunk-web"
  # Public-facing so external operators / SAML / HEC clients can reach it.
  internal                         = false
  enable_cross_zone_load_balancing = true
  load_balancer_type               = "application"
  subnets                          = local.net_lists["default"]
  security_groups                  = [lookup(local.sg_ids, "splunk_web_alb", "")]

  tags = {
    Name        = "splunk-web"
    Environment = var.environment
    source      = "terraform"
    project     = "splunk"
  }
}

resource "aws_lb_listener" "splunk_web" {
  count             = local.splunk_web_enabled
  load_balancer_arn = aws_lb.splunk_web[count.index].arn
  protocol          = "HTTPS"
  port              = 443
  certificate_arn   = aws_acm_certificate_validation.splunk_web[0].certificate_arn

  # Unknown host → 404 (rather than silently routing somewhere).
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "unknown host"
      status_code  = "404"
    }
  }
}

#-- ALB ingress (single rule replacing four per-role rules) ------------------

resource "aws_security_group_rule" "splunk_web_alb_https_from_trusted" {
  count             = local.splunk_web_enabled
  description       = "splunk-web ALB 443 from trusted_cidrs"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = lookup(local.sg_ids, "splunk_web_alb", "")
  type              = "ingress"
  cidr_blocks       = var.trusted_cidrs
}

########################### Target groups + rules ############################

# Helper to build the listener-rule host header — kept inline so each rule
# is self-contained and easy to copy when adding a new role.

#--- Cluster Manager ---------------------------------------------------------

resource "aws_lb_target_group" "splunk_manager_ui" {
  count    = local.enable_splunk_manager
  name     = "splunk-manager-ui"
  port     = 8000
  protocol = "HTTPS"
  vpc_id   = lookup(local.vpcs["default"], "id")

  health_check {
    protocol = "HTTPS"
    matcher  = "303"
    path     = "/"
    interval = 30
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 43200
  }
}

resource "aws_lb_listener_rule" "manager" {
  count        = local.enable_splunk_manager * local.splunk_web_enabled
  listener_arn = aws_lb_listener.splunk_web[0].arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.splunk_manager_ui[count.index].arn
  }

  condition {
    host_header {
      values = ["manager.${local.splunk_public_dns}"]
    }
  }
}

resource "aws_route53_record" "manager_web" {
  count   = local.enable_splunk_manager * local.splunk_web_enabled
  zone_id = lookup(local.dns["public-splunk"], "zone_id")
  name    = "manager"
  type    = "CNAME"
  ttl     = 30
  records = [aws_lb.splunk_web[0].dns_name]
}

#--- License Manager ---------------------------------------------------------

resource "aws_lb_target_group" "splunk_license_ui" {
  count                = local.enable_splunk_license
  name                 = "splunk-license-ui"
  port                 = 8000
  protocol             = "HTTPS"
  vpc_id               = lookup(local.vpcs["default"], "id")
  deregistration_delay = 60

  health_check {
    protocol = "HTTPS"
    matcher  = "303"
    path     = "/"
    interval = 30
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 43200
  }
}

resource "aws_lb_listener_rule" "license" {
  count        = local.enable_splunk_license * local.splunk_web_enabled
  listener_arn = aws_lb_listener.splunk_web[0].arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.splunk_license_ui[count.index].arn
  }

  condition {
    host_header {
      values = ["license.${local.splunk_public_dns}"]
    }
  }
}

resource "aws_route53_record" "license_web" {
  count   = local.enable_splunk_license * local.splunk_web_enabled
  zone_id = lookup(local.dns["public-splunk"], "zone_id")
  name    = "license"
  type    = "CNAME"
  ttl     = 30
  records = [aws_lb.splunk_web[0].dns_name]
}

#--- Monitoring Console ------------------------------------------------------

resource "aws_lb_target_group" "splunk_mc_ui" {
  count    = local.enable_splunk_monitoring_console
  name     = "splunk-mc-ui"
  port     = 8000
  protocol = "HTTPS"
  vpc_id   = lookup(local.vpcs["default"], "id")

  health_check {
    protocol = "HTTPS"
    matcher  = "303"
    path     = "/"
    interval = 30
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 43200
  }
}

resource "aws_lb_listener_rule" "mc" {
  count        = local.enable_splunk_monitoring_console * local.splunk_web_enabled
  listener_arn = aws_lb_listener.splunk_web[0].arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.splunk_mc_ui[count.index].arn
  }

  condition {
    host_header {
      values = ["mc.${local.splunk_public_dns}"]
    }
  }
}

resource "aws_route53_record" "mc_web" {
  count   = local.enable_splunk_monitoring_console * local.splunk_web_enabled
  zone_id = lookup(local.dns["public-splunk"], "zone_id")
  name    = "mc"
  type    = "CNAME"
  ttl     = 30
  records = [aws_lb.splunk_web[0].dns_name]
}

#--- Search Head Cluster -----------------------------------------------------

resource "aws_lb_target_group" "splunk_searchheads" {
  count                = local.enable_splunk_searchhead
  name                 = "splunk-searchheads"
  port                 = 8000
  protocol             = "HTTPS"
  vpc_id               = lookup(local.vpcs["default"], "id")
  deregistration_delay = 60

  health_check {
    protocol = "HTTPS"
    matcher  = "303"
    path     = "/"
    interval = 30
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 43200
  }
}

resource "aws_lb_listener_rule" "search" {
  count        = local.enable_splunk_searchhead * local.splunk_web_enabled
  listener_arn = aws_lb_listener.splunk_web[0].arn
  priority     = 40

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.splunk_searchheads[count.index].arn
  }

  condition {
    host_header {
      values = ["search.${local.splunk_public_dns}"]
    }
  }
}

resource "aws_route53_record" "search_web" {
  count   = local.enable_splunk_searchhead * local.splunk_web_enabled
  zone_id = lookup(local.dns["public-splunk"], "zone_id")
  name    = "search"
  type    = "CNAME"
  ttl     = 30
  records = [aws_lb.splunk_web[0].dns_name]
}

#--- HEC (Heavy Forwarder fleet) ---------------------------------------------

resource "aws_lb_target_group" "splunk_forwarder_hec" {
  count                = local.enable_splunk_forwarder
  name                 = "splunk-forwarder-hec"
  port                 = 8088
  protocol             = "HTTPS"
  vpc_id               = lookup(local.vpcs["default"], "id")
  deregistration_delay = 60

  health_check {
    protocol = "HTTPS"
    matcher  = "200"
    path     = "/services/collector/health/1.0"
    interval = 30
  }
}

resource "aws_lb_listener_rule" "hec" {
  count        = local.enable_splunk_forwarder * local.splunk_web_enabled
  listener_arn = aws_lb_listener.splunk_web[0].arn
  priority     = 50

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.splunk_forwarder_hec[count.index].arn
  }

  condition {
    host_header {
      values = ["hec.${local.splunk_public_dns}"]
    }
  }
}

resource "aws_route53_record" "hec_web" {
  count   = local.enable_splunk_forwarder * local.splunk_web_enabled
  zone_id = lookup(local.dns["public-splunk"], "zone_id")
  name    = "hec"
  type    = "CNAME"
  ttl     = 30
  records = [aws_lb.splunk_web[0].dns_name]
}

########################## CloudWatch ALB alarms #############################
# One alarm per backend TG: alerts when no healthy targets are registered.

resource "aws_cloudwatch_metric_alarm" "splunk_web_targets" {
  for_each = local.splunk_web_enabled == 0 ? {} : merge(
    local.enable_splunk_manager == 1 ? { manager = aws_lb_target_group.splunk_manager_ui[0].arn_suffix } : {},
    local.enable_splunk_license == 1 ? { license = aws_lb_target_group.splunk_license_ui[0].arn_suffix } : {},
    local.enable_splunk_monitoring_console == 1 ? { mc = aws_lb_target_group.splunk_mc_ui[0].arn_suffix } : {},
    local.enable_splunk_searchhead == 1 ? { search = aws_lb_target_group.splunk_searchheads[0].arn_suffix } : {},
    local.enable_splunk_forwarder == 1 ? { hec = aws_lb_target_group.splunk_forwarder_hec[0].arn_suffix } : {},
  )
  alarm_name          = "splunk-web-${each.key}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "splunk-web ALB has no healthy ${each.key} targets"
  datapoints_to_alarm = 1
  dimensions = {
    LoadBalancer = aws_lb.splunk_web[0].arn_suffix
    TargetGroup  = each.value
  }
  alarm_actions = [lookup(local.sns["security-alerts"], "arn")]
}
