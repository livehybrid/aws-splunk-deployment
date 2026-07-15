locals {
  roles = {
    ops = {
      name                  = aws_iam_role.ops.name
      instance_profile_name = aws_iam_instance_profile.ops.name
      instance_profile_arn  = aws_iam_instance_profile.ops.arn
      role_id               = aws_iam_instance_profile.ops.id
    }

    splunk-sh = {
      name                  = var.enable_splunk_searchhead == 1 ? aws_iam_role.splunk_sh[0].name : ""
      instance_profile_name = var.enable_splunk_searchhead == 1 ? aws_iam_instance_profile.splunk_sh[0].name : ""
      instance_profile_arn  = var.enable_splunk_searchhead == 1 ? aws_iam_instance_profile.splunk_sh[0].arn : ""
      role_id               = var.enable_splunk_searchhead == 1 ? aws_iam_instance_profile.splunk_sh[0].id : ""
    }

    splunk-manager = {
      name                  = aws_iam_role.splunk_manager.name
      instance_profile_name = aws_iam_instance_profile.splunk_manager.name
      instance_profile_arn  = aws_iam_instance_profile.splunk_manager.arn
      role_id               = aws_iam_instance_profile.splunk_manager.id
    }

    splunk-deployer = {
      name                  = aws_iam_role.splunk_deployer.name
      instance_profile_name = aws_iam_instance_profile.splunk_deployer.name
      instance_profile_arn  = aws_iam_instance_profile.splunk_deployer.arn
      role_id               = aws_iam_instance_profile.splunk_deployer.id
    }

    splunk-monitoring-console = {
      name                  = aws_iam_role.splunk_mc.name
      instance_profile_name = aws_iam_instance_profile.splunk_mc.name
      instance_profile_arn  = aws_iam_instance_profile.splunk_mc.arn
      role_id               = aws_iam_instance_profile.splunk_mc.id
    }

    splunk-license = {
      name                  = aws_iam_role.splunk_license.name
      instance_profile_name = aws_iam_instance_profile.splunk_license.name
      instance_profile_arn  = aws_iam_instance_profile.splunk_license.arn
      role_id               = aws_iam_instance_profile.splunk_license.id
    }

    splunk-forwarder = {
      name                  = aws_iam_role.splunk_forwarder.name
      instance_profile_name = aws_iam_instance_profile.splunk_forwarder.name
      instance_profile_arn  = aws_iam_instance_profile.splunk_forwarder.arn
      role_id               = aws_iam_instance_profile.splunk_forwarder.id
    }

    splunk-indexer = {
      name                  = aws_iam_role.splunk_idx.name
      instance_profile_name = aws_iam_instance_profile.splunk_idx.name
      instance_profile_arn  = aws_iam_instance_profile.splunk_idx.arn
      role_id               = aws_iam_instance_profile.splunk_idx.id
    }
  }
}

output "roles" {
  value = local.roles
}
