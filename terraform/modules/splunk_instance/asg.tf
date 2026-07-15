###############################################################################
# Per-host elastic IP (optional, used for SH/HF/manager).
###############################################################################

resource "aws_eip" "static_ip" {
  domain = "vpc"
  count  = var.create_elastic_ip * local.enabled * var.desired_count

  tags = {
    Name = "${replace(local.name, "-", "_")}_${local.az_letter}_${count.index}"
  }
}

###############################################################################
# Per-host EBS volumes.
#
# Indexers get a single "cache" volume mounted at /opt/splunk/var/lib/splunk
# (SmartStore-backed: warm/cold tier lives in S3, only hot+cache lives on EBS).
#
# Heavy Forwarders optionally get a checkpoint volume for queues/modinputs.
###############################################################################

resource "aws_ebs_volume" "splunkdb_vol_cache" {
  availability_zone = var.availability_zone
  size              = var.hot_disk_size
  encrypted         = true
  type              = "gp3"
  iops              = 3000
  throughput        = 250

  count = var.role == "indexer" ? local.enabled * var.desired_count : 0

  tags = {
    Name        = "${var.environment}-${var.role}-${local.az_letter}-${count.index}-cache"
    project     = "splunk"
    heat        = "cache"
    location    = var.availability_zone
    indexer_num = count.index
    environment = var.environment
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_ebs_volume" "splunkdb_vol_checkpoint" {
  availability_zone = var.availability_zone
  size              = var.checkpoint_disk_size
  encrypted         = true
  type              = "gp3"

  count = var.role == "heavy-forwarder" ? local.enabled * var.desired_count * var.attach_checkpoint_ebs : 0

  tags = {
    Name        = "${var.environment}-${var.custom_name}-${local.az_letter}-${count.index}-checkpoint"
    project     = "splunk"
    heat        = "checkpoint"
    location    = var.availability_zone
    hf_num      = count.index
    environment = var.environment
  }

  lifecycle {
    prevent_destroy = false
  }
}

###############################################################################
# Launch template (provider 5.x compliant; IMDSv2 enforced; gp3 root volume).
###############################################################################

resource "aws_launch_template" "splunk" {
  count = local.enabled
  name  = "${local.name}-${local.az_letter}-${count.index}"

  image_id      = var.ami_id
  instance_type = local.instance_size
  key_name      = var.keypair_name
  ebs_optimized = var.ebs_optimized

  disable_api_termination              = false
  instance_initiated_shutdown_behavior = "terminate"

  iam_instance_profile {
    name = var.instance_profile_name
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.os_volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  metadata_options {
    http_tokens                 = var.imds_http_tokens
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  # Spot instances when var.use_spot=true. Persistent spot survives stop/start
  # cycles, but for our ASG we use "one-time" — if AWS reclaims, the ASG
  # launches a fresh instance. SmartStore means recovery is just a cluster
  # rejoin + cache repopulate, not a data restore.
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type = "one-time"
      }
    }
  }

  network_interfaces {
    delete_on_termination       = true
    associate_public_ip_address = var.associate_public_ip_address
    subnet_id                   = lookup(local.net["default"], var.availability_zone)
    security_groups             = var.security_groups
  }

  placement {
    availability_zone = var.availability_zone
    partition_number  = 0
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.name}-${count.index}"
    }
  }

  user_data = data.cloudinit_config.splunk.rendered
}

###############################################################################
# Auto-scaling group.
###############################################################################

resource "aws_autoscaling_group" "splunk-asg" {
  count = local.enabled * var.desired_count
  name  = "${local.name}-${local.az_letter}-${count.index}"

  launch_template {
    id      = aws_launch_template.splunk[0].id
    version = aws_launch_template.splunk[0].latest_version
  }

  desired_capacity = var.asg_desired_size
  min_size         = 0
  max_size         = var.asg_max_size

  # ELB-type checks replace instances whose splunkd dies while EC2 stays
  # healthy. Default stays EC2 — flip per-role once the cluster is stable so
  # auto-replacement doesn't churn instances during bring-up/diagnosis.
  health_check_type         = var.health_check_type
  health_check_grace_period = var.health_check_grace_period

  target_group_arns   = var.target_group
  vpc_zone_identifier = [lookup(local.net["default"], var.availability_zone)]

  enabled_metrics = [
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  depends_on = [aws_launch_template.splunk]

  tag {
    key                 = "Name"
    value               = "${replace(local.name, "-", "_")}_${local.az_letter}_${count.index}"
    propagate_at_launch = true
  }
  tag {
    key                 = "role"
    value               = var.role
    propagate_at_launch = true
  }
  tag {
    key                 = "source"
    value               = local.name
    propagate_at_launch = true
  }
  tag {
    key                 = "project"
    value               = "splunk"
    propagate_at_launch = true
  }
  tag {
    key                 = "environment"
    value               = var.environment
    propagate_at_launch = true
  }
  tag {
    key                 = "PatchGroup"
    value               = "${var.environment}_${local.az_letter}"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = []
  }
}

###############################################################################
# Health alarm.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "ec2-cpu" {
  count               = local.enabled * var.desired_count
  alarm_name          = "${local.name}-${local.az_letter}-${count.index}-cpu"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "3"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "90"

  dimensions = {
    AutoScalingGroupName = element(aws_autoscaling_group.splunk-asg.*.name, count.index)
  }

  alarm_description = "This metric monitors EC2 CPU utilization"
  alarm_actions     = [lookup(local.sns["security-alerts"], "arn")]
}
