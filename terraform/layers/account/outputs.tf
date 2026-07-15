###############################################################################
# Outputs consumed by the iam and cluster layers via terraform_remote_state.
#
# Trimmed to C3-only — no legacy edge cruft (loaders, DSP, SES, publishing,
# sftp, deployment-server-external, etc.).
###############################################################################

locals {
  kms = {
    pki = {
      arn = aws_kms_key.pki.arn
    }
    checkpoints = {
      arn = aws_kms_key.checkpoints.arn
    }
    splunk-smartstore = {
      arn = var.enable_smartstore == 1 ? element(concat(aws_kms_key.splunk-smartstore.*.arn, [""]), 0) : ""
    }
  }

  endpoints = {
    s3 = {
      prefix_list_id = aws_vpc_endpoint.ep_s3.prefix_list_id
    }
    kms = {
      sg_id = aws_security_group.ep_kms.id
    }
    ec2 = {
      sg_id = aws_security_group.ep_ec2.id
    }
    elb = {
      sg_id = aws_security_group.ep_elb.id
    }
    ssm = {
      sg_id = aws_security_group.ep_ssm.id
    }
    logs = {
      sg_id = aws_security_group.ep_logs.id
    }
    events = {
      sg_id = aws_security_group.ep_events.id
    }
    monitoring = {
      sg_id = aws_security_group.ep_monitoring.id
    }
  }

  s3 = {
    resources = {
      name = aws_s3_bucket.resources.bucket
      arn  = aws_s3_bucket.resources.arn
    }
    ma-certs = {
      name = aws_s3_bucket.ma-certs.bucket
      arn  = aws_s3_bucket.ma-certs.arn
    }
    checkpoints = {
      name = aws_s3_bucket.checkpoints.bucket
      arn  = aws_s3_bucket.checkpoints.arn
    }
    splunk-smartstore = {
      name = var.enable_smartstore == 1 ? element(concat(aws_s3_bucket.splunk_smartstore.*.bucket, [""]), 0) : ""
      arn  = var.enable_smartstore == 1 ? element(concat(aws_s3_bucket.splunk_smartstore.*.arn, [""]), 0) : ""
    }
  }

  sns = {
    security-alerts = {
      name = module.slack_alert.name
      id   = module.slack_alert.id
      arn  = module.slack_alert.sns_arn
    }
  }

  dns = {
    private = {
      zone_id = aws_route53_zone.private.zone_id
      name    = replace(aws_route53_zone.private.name, "/[.]$/", "")
    }
    public-splunk = {
      zone_id = element(
        concat(
          aws_route53_zone.public-splunk.*.zone_id,
          data.aws_route53_zone.public-splunk.*.zone_id,
        ),
        0,
      )
      name = replace(
        element(
          concat(
            aws_route53_zone.public-splunk.*.name,
            data.aws_route53_zone.public-splunk.*.name,
          ),
          0,
        ),
        "/[.]$/",
        "",
      )
    }
    public-inputs = {
      zone_id = var.enable_splunk_forwarder == 1 ? element(concat(aws_route53_zone.public-inputs.*.id, [""]), 0) : ""
      name    = var.enable_splunk_forwarder == 1 ? element(concat(aws_route53_zone.public-inputs.*.name, [""]), 0) : ""
    }
  }

  vpcs = {
    default = {
      id   = aws_vpc.default.id
      cidr = aws_vpc.default.cidr_block
    }
  }

  net = {
    default = {
      eu-west-2a = aws_subnet.default_a.id
      eu-west-2b = aws_subnet.default_b.id
      eu-west-2c = aws_subnet.default_c.id
    }
  }

  net_lists = {
    default = [
      aws_subnet.default_a.id,
      aws_subnet.default_b.id,
      aws_subnet.default_c.id,
    ]
  }

  key_names = {
    ops = aws_key_pair.ops.key_name
  }

  secrets = {
    ca-password = {
      arn = aws_secretsmanager_secret.ca-password.arn
      id  = aws_secretsmanager_secret.ca-password.id
    }
    license = {
      arn = aws_secretsmanager_secret.license.arn
      id  = aws_secretsmanager_secret.license.id
    }
    slack-webook = {
      arn = aws_secretsmanager_secret.alerts_slack_webhook.arn
      id  = aws_secretsmanager_secret.alerts_slack_webhook.id
    }
    ops-private-key = {
      arn = aws_secretsmanager_secret.ops_private_key.arn
      id  = aws_secretsmanager_secret.ops_private_key.id
    }
  }

  sg_ids = {
    splunk_indexer        = var.enable_splunk_indexer == 1 ? element(concat(aws_security_group.splunk_indexer.*.id, [""]), 0) : ""
    splunk_manager        = var.enable_splunk_manager == 1 ? element(concat(aws_security_group.splunk_manager.*.id, [""]), 0) : ""
    splunk_manager_access = var.enable_splunk_manager == 1 ? element(concat(aws_security_group.splunk_manager_access.*.id, [""]), 0) : ""
    splunk_searchhead     = var.enable_splunk_searchhead == 1 ? element(concat(aws_security_group.splunk_searchhead.*.id, [""]), 0) : ""
    splunk_forwarder      = var.enable_splunk_forwarder == 1 ? element(concat(aws_security_group.splunk_forwarder.*.id, [""]), 0) : ""
    splunk_license        = var.enable_splunk_license == 1 ? element(concat(aws_security_group.splunk_license.*.id, [""]), 0) : ""
    splunk_web_alb        = element(concat(aws_security_group.splunk_web_alb.*.id, [""]), 0)
    splunk_alb            = aws_security_group.splunk_alb.id
  }

  roles = {
    lambda-alert = {
      name = aws_iam_role.lambda.name
      arn  = aws_iam_role.lambda.arn
    }
  }
}

output "kms" {
  value = local.kms
}

output "s3" {
  value = local.s3
}

output "dns" {
  value = local.dns
}

output "vpcs" {
  value = local.vpcs
}

output "net" {
  value = local.net
}

output "net_lists" {
  value = local.net_lists
}

output "key_names" {
  value = local.key_names
}

output "secrets" {
  value = local.secrets
}

output "sg_ids" {
  value = local.sg_ids
}

output "endpoints" {
  value = local.endpoints
}

output "sns" {
  value = local.sns
}

output "roles" {
  value = local.roles
}
