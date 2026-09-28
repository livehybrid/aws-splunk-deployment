# S3 gateway endpoint policy: reach the persistent SOK buckets (SmartStore, the
# App-Framework apps bucket and the KV-store backups) over the endpoint, without
# a NAT. Listing is allowed account-wide so the operator/CLIs can resolve them.
data "aws_iam_policy_document" "vpce_s3_policy" {
  statement {
    sid     = "AllowAccessToKnownS3"
    actions = ["s3:*"]

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    resources = [
      aws_s3_bucket.smartstore.arn, "${aws_s3_bucket.smartstore.arn}/*",
      aws_s3_bucket.apps.arn, "${aws_s3_bucket.apps.arn}/*",
      aws_s3_bucket.kvbackup.arn, "${aws_s3_bucket.kvbackup.arn}/*",
    ]
  }

  statement {
    sid     = "AllowListingOfMyBuckets"
    actions = ["s3:ListAllMyBuckets", "s3:GetBucketLocation", "s3:ListBucket"]
    principals {
      identifiers = ["*"]
      type        = "*"
    }
    resources = ["*"]
  }

  # ECR image layer data is served from regional S3 buckets (prod-<region>-
  # starport-layer-bucket). Without this, pulls via the ECR VPC endpoint get
  # 403 Forbidden because the gateway endpoint policy denies unlisted buckets.
  statement {
    sid     = "AllowECRImageLayerPulls"
    actions = ["s3:GetObject"]

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    resources = ["arn:aws:s3:::prod-${var.region}-starport-layer-bucket/*"]
  }
  # Amazon Linux 2023 package repositories are S3-hosted too (al2023-repos-
  # <region>-<id>). eks/files/nvme-raid.sh installs mdadm at boot, so without
  # this every nvme_local_storage node fails to assemble its RAID behind the
  # gateway endpoint.
  statement {
    sid     = "AllowAL2023Repos"
    actions = ["s3:GetObject"]
    principals {
      identifiers = ["*"]
      type        = "*"
    }
    resources = ["arn:aws:s3:::al2023-repos-${var.region}-*/*"]
  }
  # The AI tier's model weights and artifacts (ai.tf). Ray and SAIA read and
  # write through this endpoint; unlisted, every weight download is a 403.
  dynamic "statement" {
    for_each = var.ai_tier_enabled ? [1] : []
    content {
      sid     = "AllowAITierArtifacts"
      actions = ["s3:*"]
      principals {
        identifiers = ["*"]
        type        = "*"
      }
      resources = [aws_s3_bucket.ai[0].arn, "${aws_s3_bucket.ai[0].arn}/*"]
    }
  }
}

resource "aws_vpc_endpoint" "ep_s3" {
  vpc_id       = aws_vpc.default.id
  policy       = data.aws_iam_policy_document.vpce_s3_policy.json
  service_name = "com.amazonaws.${var.region}.s3"
  tags = {
    Name = "S3"
  }
}

resource "aws_vpc_endpoint_route_table_association" "s3_default_rt" {
  vpc_endpoint_id = aws_vpc_endpoint.ep_s3.id
  route_table_id  = aws_default_route_table.default.id
}

resource "aws_security_group" "ep_kms" {
  name        = "kms-vpc-endpoints-sg"
  description = "kms-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "kms-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "ep_kms" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "kms") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.kms"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_kms.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "KMS"
  }
}

resource "aws_security_group" "ep_ec2" {
  name        = "ec2-vpc-endpoints-sg"
  description = "ec2-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "ec2-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "ep_ec2" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "ec2") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.ec2"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_ec2.id
  ]

  private_dns_enabled = true
  tags = {
    Name = "EC2"
  }
}

resource "aws_security_group" "ep_elb" {
  name        = "elb-vpc-endpoints-sg"
  description = "elb-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "elb-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "ep_elb" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "elb") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.elasticloadbalancing"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_elb.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "ELB"
  }
}

resource "aws_security_group" "ep_ssm" {
  name        = "ssm-vpc-endpoints-sg"
  description = "ssm-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "ssm-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "ep_ssm" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "ssm") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_ssm.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "SSM"
  }
}

resource "aws_vpc_endpoint" "ep_ssmmessages" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "ssm") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_ssm.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "SSMMessages"
  }
}

resource "aws_security_group" "ep_logs" {
  name        = "logs-vpc-endpoints-sg"
  description = "logs-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "logs-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "ep_logs" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "logs") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.logs"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_logs.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "Logs"
  }
}

resource "aws_security_group" "ep_events" {
  name        = "events-vpc-endpoints-sg"
  description = "events-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "events-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "ep_events" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "events") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.events"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_events.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "Events"
  }
}

resource "aws_security_group" "ep_monitoring" {
  name        = "monitoring-vpc-endpoints-sg"
  description = "monitoring-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "monitoring-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "ep_monitoring" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "monitoring") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.monitoring"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ep_monitoring.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "Monitoring"
  }
}

resource "aws_security_group" "sns" {
  name        = "sns-vpc-endpoints-sg"
  description = "sns-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "sns-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "sns" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "sns") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.sns"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.sns.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "SNS"
  }
}

resource "aws_security_group" "sqs" {
  name        = "sqs-vpc-endpoints-sg"
  description = "sqs-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "sqs-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      "192.168.23.0/24",
    ]
  }
}

resource "aws_security_group" "ecr" {
  name        = "ecr-vpc-endpoints-sg"
  description = "ecr-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "ecr-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}

resource "aws_vpc_endpoint" "sqs" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "sqs") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.sqs"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.sqs.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "SQS"
  }
}

resource "aws_vpc_endpoint" "ecr" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "ecr") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ecr.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "ECR"
  }
}

resource "aws_vpc_endpoint" "ecrapi" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "ecr") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.ecr.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "ECRAPI"
  }
}


resource "aws_security_group" "sts" {
  name        = "sts-vpc-endpoints-sg"
  description = "sts-vpc-endpoints-sg"

  vpc_id = aws_vpc.default.id

  tags = {
    Name = "sts-vpc-endpoints-sg"
  }

  ingress {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443

    cidr_blocks = [
      var.default_vpc_cidr,
    ]
  }
}


resource "aws_vpc_endpoint" "sts" {
  count             = var.enable_vpc_endpoints && contains(var.vpc_endpoint_services, "sts") ? 1 : 0
  vpc_id            = aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.net_lists["default"]

  security_group_ids = [
    aws_security_group.sts.id,
  ]

  private_dns_enabled = true
  tags = {
    Name = "STS"
  }
}