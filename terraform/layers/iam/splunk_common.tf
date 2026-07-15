#SPLUNK sym password.
# Splunk 10 warns when pass4SymmKey < 32 chars (HTTPAuthManager). 64 is comfortable.
resource "random_string" "splunk_pass4SymmKey" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "splunk_pass4SymmKey" {
  name = "/splunk/pass4SymmKey"
}

resource "aws_secretsmanager_secret_version" "splunk_pass4SymmKey" {
  secret_id     = aws_secretsmanager_secret.splunk_pass4SymmKey.id
  secret_string = random_string.splunk_pass4SymmKey.result
}

#SPLUNK Admin password
resource "random_string" "splunk_admin_password" {
  length  = 12
  special = false
}

resource "aws_secretsmanager_secret" "splunk_admin_password" {
  name        = "/monitoring/splunk/password"
  description = "Splunk admin account password (username from var.splunk_admin_username)."
}

resource "aws_secretsmanager_secret_version" "splunk_password" {
  secret_id     = aws_secretsmanager_secret.splunk_admin_password.id
  secret_string = random_string.splunk_admin_password.result
}

#SPLUNK Encryption key
resource "random_string" "splunk_secret_key" {
  length  = 254
  special = false
}

resource "aws_secretsmanager_secret" "splunk_secret_key" {
  name = "/monitoring/splunk/secret_key"
}

resource "aws_secretsmanager_secret_version" "splunk_secret_key" {
  secret_id     = aws_secretsmanager_secret.splunk_secret_key.id
  secret_string = random_string.splunk_secret_key.result
}

data "aws_iam_policy_document" "sns-security-alert" {
  statement {
    actions = [
      "sns:Publish",
    ]

    resources = ["arn:aws:sns:eu-west-2:${local.account_id}:security-alerts-topic"]
  }

  statement {
    actions = [
      "sns:ListTopics",
    ]

    resources = ["*"]
  }
}

//data "aws_iam_policy_document" "sqs-config-changes" {
//
//  statement {
//    actions = [
//      "sqs:DeleteMessage",
//      "sqs:DeleteMessageBatch",
//      "sqs:GetQueueAttributes",
//      "sqs:GetQueueUrl",
//      "sqs:ReceiveMessage"
//    ]
//    resources = ["arn:aws:sqs:eu-west-2:${local.account_id}:config-changes"]
//  }
//
//  statement {
//    actions = [
//      "sqs:ListQueues",
//    ]
//
//    resources = ["*"]
//  }
//
//}
data "aws_iam_policy_document" "splunk" {
  statement {
    sid = "GetAlias"
    actions = [
      "iam:ListAccountAliases"
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
    ]

    resources = ["*"]
  }

  statement {
    actions = local.iam_s3_list_bucket_actions

    resources = [
      lookup(local.s3["resources"], "arn"),
      lookup(local.s3["ma-certs"], "arn"),
    ]
  }

  statement {
    actions = [
      "s3:ListAllMyBuckets",
    ]

    resources = ["*"]
  }

  statement {
    actions = local.iam_s3_list_bucket_actions

    resources = [
      "${lookup(local.s3["resources"], "arn")}/*",
      "${lookup(local.s3["ma-certs"], "arn")}/*",
    ]
  }

  statement {
    actions = local.iam_s3_read_only_actions

    # ma-certs deliberately absent: it holds the CA private key, which only
    # the cert-issuer Lambda may read. Instances get ca/*.crt via the
    # narrower s3_ca_crt_access policy attached per-role.
    resources = [
      "${lookup(local.s3["resources"], "arn")}/*",
    ]

  }

  # Boot-time certificate issuance: instances send a CSR to the per-env
  # issuer Lambda and receive a CA-signed cert back.
  statement {
    actions = ["lambda:InvokeFunction"]

    resources = [
      "arn:aws:lambda:eu-west-2:${local.account_id}:function:splunk-cert-issuer-*",
    ]
  }

  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "ssm:GetParameters",
    ]

    resources = [
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/monitoring/splunk/*",
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/splunk/*",
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/monitoring/alerts/slack_webhook",
      "arn:aws:ssm:eu-west-2:${local.account_id}:parameter/aws/reference/secretsmanager//splunk/*",
    ]
  }

  statement {
    actions = [
      "support:DescribeTrustedAdvisorCheckResult",
      "support:DescribeTrustedAdvisorCheckSummaries",
      "support:DescribeServices",
      "support:DescribeTrustedAdvisorCheckRefreshStatuses",
      "support:DescribeTrustedAdvisorChecks",
      "support:DescribeSeverityLevels",
      "support:RefreshTrustedAdvisorCheck",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [
      "arn:aws:route53:::hostedzone/${lookup(local.dns["private"], "zone_id")}",
    ]
  }
}

data "aws_iam_policy_document" "s3_ca_crt_access" {
  statement {
    actions = local.iam_s3_read_only_actions

    resources = [
      "${lookup(local.s3["ma-certs"], "arn")}/ca/*.crt",
    ]
  }

  statement {
    actions = local.iam_kms_decrypt_actions

    resources = [
      lookup(local.kms["pki"], "arn"),
    ]
  }
}


data "aws_iam_policy_document" "lambda_get_lic_auth_certs" {
  statement {
    actions = [
      "lambda:InvokeFunction",
    ]

    resources = [
      "arn:aws:lambda:eu-west-2:*:function:get_authorisedcerts",
    ]
  }
}

data "aws_iam_policy_document" "ssm_policy" {
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
}

data "aws_iam_policy_document" "splunk_secret_file" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:UpdateSecret",
      "secretsmanager:CreateSecret",
      "secretsmanager:GetRandomPassword"
    ]

    resources = [
      "arn:aws:secretsmanager:eu-west-2:${local.account_id}:secret:/splunk/secret/*"
    ]
  }
}

data "aws_iam_policy_document" "private_route53" {
  statement {
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${lookup(local.dns["private"], "zone_id")}"
    ]
  }
}
