###############################################################################
# Route53 zones for the LiveHybrid Splunk C3 deployment.
#
# - public-splunk:  external-facing DNS for ALB/ACM endpoints.
# - public-inputs:  HEC/inputs subdomain (split for tighter scoping).
# - private:        VPC-internal zone for cluster mesh DNS.
###############################################################################

resource "aws_route53_zone" "public-splunk" {
  count = var.create_dns ? 1 : 0
  name  = var.dns_base_splunk_domain

  tags = {
    environment = var.environment
    project     = "splunk"
  }
}

data "aws_route53_zone" "public-splunk" {
  count = var.create_dns ? 0 : 1
  name  = var.dns_base_splunk_domain
}

resource "aws_route53_zone" "public-inputs" {
  count = var.enable_splunk_forwarder
  name  = "inputs.${var.dns_base_splunk_domain}"

  tags = {
    environment = var.environment
    project     = "splunk"
  }
}

resource "aws_route53_record" "public-inputs" {
  count   = var.enable_splunk_forwarder
  zone_id = local.dns["public-splunk"]["zone_id"]
  name    = "inputs.${var.dns_base_splunk_domain}"
  type    = "NS"
  ttl     = 30

  records = [
    aws_route53_zone.public-inputs[0].name_servers[0],
    aws_route53_zone.public-inputs[0].name_servers[1],
    aws_route53_zone.public-inputs[0].name_servers[2],
    aws_route53_zone.public-inputs[0].name_servers[3],
  ]
}

resource "aws_route53_zone" "private" {
  name = "${var.environment}.splunk.internal"

  vpc {
    vpc_id     = aws_vpc.default.id
    vpc_region = var.region
  }

  tags = {
    environment = var.environment
    project     = "splunk"
  }
}

# Route53's default SOA negative-TTL is 900s: an instance that looks up a
# cluster name before its A record lands gets NXDOMAIN cached at the VPC
# resolver for 15 minutes — exactly the cold-start "indexer cannot reach
# manager" race. 60s keeps that window shorter than one bootstrap retry.
resource "aws_route53_record" "private_soa" {
  zone_id         = aws_route53_zone.private.zone_id
  name            = aws_route53_zone.private.name
  type            = "SOA"
  ttl             = 60
  allow_overwrite = true

  records = [
    "${aws_route53_zone.private.primary_name_server} awsdns-hostmaster.amazon.com. 1 7200 900 1209600 60",
  ]
}
