###############################################################################
# Splunk Monitoring Console — single instance, distributed search peer of all
# the other cluster roles.
###############################################################################

module "monitoring_console" {
  source                 = "../../modules/splunk_instance"
  ssl_verify_server_cert = var.ssl_verify_server_cert
  enabled                = local.enable_splunk_monitoring_console

  environment           = var.environment
  use_spot              = var.use_spot
  ami_id                = var.splunk_ami
  keypair_name          = local.key_names["ops"]
  instance_profile_name = lookup(local.roles["splunk-monitoring-console"], "instance_profile_name")
  splunk_admin_username = var.splunk_admin_username

  dns               = local.dns
  vpcs              = local.vpcs
  net               = local.net
  sg_ids            = local.sg_ids
  sns               = local.sns
  s3                = local.s3
  role              = "monitoring_console"
  availability_zone = "eu-west-2a"
  cn_name           = var.pki_cn_name

  security_groups             = [local.sg_ids["splunk_searchhead"]]
  associate_public_ip_address = true
  instance_size               = var.custom_instance_type_monitoring_console

  desired_count = "1"
  asg_max_size  = local.enable_splunk_monitoring_console
  target_group  = tolist([element(concat(aws_lb_target_group.splunk_mc_ui.*.id, tolist([""])), 0)])
}
