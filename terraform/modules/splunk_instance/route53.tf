resource "aws_route53_record" "host_dns" {
  count   = var.role == "heavy-forwarder" ? var.enabled * var.desired_count * var.create_elastic_ip : 0
  name    = "${replace(local.name, "-", "_")}_${local.az_letter}_${count.index}"
  type    = "A"
  ttl     = 60
  zone_id = lookup(local.dns["public-splunk"], "zone_id")
  records = [element(aws_eip.static_ip.*.public_ip, count.index)]
}