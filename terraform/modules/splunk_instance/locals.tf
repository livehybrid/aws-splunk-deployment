data "aws_ami" "splunk" {
  name_regex = "^splunk-enterprise-.*"

  owners = [
    "self",
  ]

  most_recent = true
}

locals {
  //${element(local.net["default_subnet_ids"], 0)}
  az_letter              = replace(element(split("-", var.availability_zone), 2), "/\\d/", "")
  ami_id                 = var.ami_id != "" ? var.ami_id : data.aws_ami.splunk.image_id
  dns                    = var.dns
  net                    = var.net
  vpcs                   = var.vpcs
  sns                    = var.sns
  vpc_id                 = lookup(local.vpcs["default"], "id")
  sg_id                  = var.sg_ids
  pass4SymmKey           = var.pass4SymmKey != "" ? var.pass4SymmKey : data.aws_secretsmanager_secret_version.pass4SymmKey.secret_string
  external-domain        = lookup(local.dns["public-splunk"], "name")
  internal-domain        = lookup(local.dns["private"], "name")
  name                   = var.custom_name != "" ? format("%s-%s", var.environment, var.custom_name) : format("%s-%s", var.environment, var.role)
  enable_idx_clustering  = var.enable_splunk_indexers
  additional_server_conf = local.manager_idx_clustering
  instance_size          = coalesce(var.instance_size, var.default_instance_size)
  enabled                = var.enabled * var.desired_count > 0 ? 1 : 0
}
