
resource "aws_route53_record" "splunk_forwarder" {
  count   = local.enable_splunk_forwarder
  name    = ""
  type    = "A"
  zone_id = lookup(local.dns["public-inputs"], "zone_id")
  #  ttl     = 60
  #  records = ["${local.heavy_fowarder_eips}"]
  alias {
    name                   = aws_lb.splunk_forwarder[0].dns_name
    zone_id                = aws_lb.splunk_forwarder[0].zone_id
    evaluate_target_health = true
  }
  //  lifecycle {
  //    # REMOVE THIS IN FUTURE RELEASE TO UPDATE TO USING ELASTIC IPS
  //    ignore_changes = [
  //      "records", "alias", "ttl"
  //    ]
  //  }

}

resource "aws_route53_record" "edge_inputs" {
  count   = local.enable_splunk_forwarder * (length(local.heavy_fowarder_eips) > 0 ? 1 : 0)
  name    = "edge"
  type    = "A"
  zone_id = lookup(local.dns["public-splunk"], "zone_id")
  ttl     = 60
  records = local.heavy_fowarder_eips
}

resource "aws_route53_record" "splunk_forwarder_internal" {
  count   = local.enable_splunk_forwarder
  name    = "inputs"
  type    = "A"
  zone_id = lookup(local.dns["private"], "zone_id")

  alias {
    name                   = aws_lb.splunk_forwarder[0].dns_name
    zone_id                = aws_lb.splunk_forwarder[0].zone_id
    evaluate_target_health = true
  }
}
