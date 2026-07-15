############ ...OPS... ###############

data "aws_iam_policy_document" "ops" {
  statement {
    sid = "GetAlias"
    actions = [
      "iam:ListAccountAliases"
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "ssm:DescribeAssociation",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:DescribeDocument",
      "ssm:GetManifest",
      "ssm:GetParameters",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:PutInventory",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]

    resources = [
      "*",
    ]
  }


  statement {
    actions = [
      "ec2:Describe*",
      "rds:Describe*",
      "elasticache:Describe*",
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets"
    ]

    resources = [
      "*",
    ]
  }

  statement {
    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "arn:aws:s3:::${local.account_name}-terraform",
      lookup(local.s3["resources"], "arn"),
    ]
  }

  statement {
    actions = [
      "secretsmanager:GetSecretValue"
    ]

    resources = [
      lookup(local.secrets["ops-private-key"], "arn"),
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/git/*",
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/monitoring/splunk/password*"
    ]
  }

  # read write buckets
  statement {
    actions = local.iam_s3_read_write_actions

    resources = [
      "arn:aws:s3:::${local.account_name}-terraform/*",
      lookup(local.s3["resources"], "arn"),
    ]
  }
}

resource "aws_iam_role_policy" "ops" {
  name   = aws_iam_role.ops.name
  role   = aws_iam_role.ops.name
  policy = data.aws_iam_policy_document.ops.json
}

resource "aws_iam_instance_profile" "ops" {
  name = aws_iam_role.ops.name
  role = aws_iam_role.ops.name
}

resource "aws_iam_role" "ops" {
  name                  = "Ops"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "bastion_route53" {
  statement {
    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [
      "arn:aws:route53:::hostedzone/${lookup(local.dns["public-splunk"], "zone_id")}",
      "arn:aws:route53:::hostedzone/${lookup(local.dns["private"], "zone_id")}",
    ]
  }
}

resource "aws_iam_role_policy" "ops_bastion_route53" {
  name   = "${aws_iam_role.ops.name}-bastion_route53"
  role   = aws_iam_role.ops.name
  policy = data.aws_iam_policy_document.bastion_route53.json
}
