###############################################################################
# Splunk License Manager — single instance.
###############################################################################

resource "aws_eip" "license_server" {
  count  = local.enable_splunk_license
  domain = "vpc"

  tags = {
    Name = "license_server_eip"
    host = "license"
  }
}

module "license" {
  source                 = "../../modules/splunk_instance"
  ssl_verify_server_cert = var.ssl_verify_server_cert
  enabled                = local.enable_splunk_license

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-license"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  role              = "license"
  availability_zone = "eu-west-2a"
  cn_name           = var.pki_cn_name

  security_groups             = [local.sg_ids["splunk_license"]]
  associate_public_ip_address = true
  instance_size               = var.custom_instance_type_license
  create_elastic_ip           = 0

  target_group = tolist([
    element(concat(aws_lb_target_group.splunk_license_ui.*.id, tolist([""])), 0),
    element(concat(aws_lb_target_group.splunk_license.*.id, tolist([""])), 0),
  ])

  desired_count = "1"
  asg_max_size  = local.enable_splunk_license
}

# license.<public domain> is a CNAME to the splunk-web ALB (splunk_web_alb.tf);
# the legacy direct-to-EIP A record it replaced lived here.
