packer {
  required_version = ">= 1.11"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

variable "aws_profile" {
  type        = string
  default     = ""
  description = "AWS profile to use for the build. Empty = SDK default chain (used in CI with OIDC)."
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID the AMI is built in."
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

# Optional — empty means the default VPC + its default subnet are used.
variable "vpc_subnet" {
  type        = string
  default     = ""
  description = "Subnet ID for the Packer builder. Empty = default VPC."
}

# Optional — empty means Packer creates a temporary SG with SSH from
# temporary_security_group_source_cidrs. Provide one to reuse an existing SG.
variable "security_group_id" {
  type        = string
  default     = ""
  description = "Security group for the Packer builder. Empty = temporary SG."
}

variable "temporary_sg_source_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed SSH to the temporary builder SG (only used when security_group_id is empty)."
}

# Optional — empty skips. The build only downloads public artefacts, so an
# instance profile is unnecessary for a vanilla AMI build.
variable "iam_instance_profile" {
  type        = string
  default     = ""
  description = "Optional instance profile for the Packer builder."
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "splunk_version" {
  type        = string
  description = "Splunk Enterprise version. See https://raw.githubusercontent.com/livehybrid/downloadSplunk/refs/heads/main/version.list"
  default     = "10.4.0"
}

variable "splunk_build" {
  type        = string
  description = "Splunk Enterprise build hash matching the version."
  default     = "f798d4d49089"
}

variable "name" {
  type    = string
  default = "splunk-enterprise"
}

# Amazon Linux 2023 base AMI lookup. AL2023 is owned by Amazon (137112412989).
source "amazon-ebs" "splunk_enterprise" {
  ami_name      = "${var.name}-${var.splunk_version}-${var.splunk_build}-{{ timestamp }}"
  region        = var.region
  profile       = var.aws_profile
  instance_type = var.instance_type
  subnet_id     = var.vpc_subnet

  encrypt_boot         = true
  iam_instance_profile = var.iam_instance_profile
  security_group_id    = var.security_group_id != "" ? var.security_group_id : null

  temporary_security_group_source_cidrs = var.security_group_id == "" ? var.temporary_sg_source_cidrs : []

  ssh_username = "ec2-user"
  ssh_pty      = false

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-*-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
      architecture        = "x86_64"
    }
    owners      = ["137112412989"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  run_tags = {
    Name    = "packer-build-${var.name}-${var.splunk_version}"
    project = "splunk"
    source  = "packer"
  }
  snapshot_tags = {
    Name    = "${var.name}-${var.splunk_version}-${var.splunk_build}"
    project = "splunk"
    source  = "packer"
  }
  tags = {
    Name           = "${var.name}-${var.splunk_version}-${var.splunk_build}"
    splunk_version = var.splunk_version
    splunk_build   = var.splunk_build
    os             = "al2023"
    project        = "splunk"
    source         = "packer"
  }
}

build {
  name    = "splunk-enterprise"
  sources = ["source.amazon-ebs.splunk_enterprise"]

  # Patch base OS. (curl/tar/unzip/chrony/vim ship with AL2023 already — we don't
  # `dnf install curl` because it conflicts with the preinstalled curl-minimal.)
  provisioner "shell" {
    inline = [
      "sudo dnf -y upgrade --refresh",
      "sudo dnf -y install git jq htop rsync policycoreutils-python-utils",
      "sudo systemctl enable --now chronyd",
    ]
  }

  # CloudWatch Agent (preinstalled SSM Agent is fine as-is).
  provisioner "shell" {
    inline = [
      "sudo dnf -y install amazon-cloudwatch-agent",
    ]
  }

  provisioner "file" {
    source      = "files/cloudwatch-config.json"
    destination = "/tmp/cloudwatch-config.json"
  }

  provisioner "shell" {
    inline = [
      "sudo install -m 0644 -o root -g root /tmp/cloudwatch-config.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json",
      "sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s",
    ]
  }

  # Splunk ulimits — required for nofile=64000, nproc=16000.
  provisioner "file" {
    source      = "files/etc/security/limits.d/splunk.conf"
    destination = "/tmp/splunk-limits.conf"
  }

  provisioner "shell" {
    inline = [
      "sudo install -m 0644 -o root -g root /tmp/splunk-limits.conf /etc/security/limits.d/99-splunk.conf",
    ]
  }

  # Download and install Splunk Enterprise.
  # Splunk 10+ RPM filename pattern: splunk-<ver>-<build>.x86_64.rpm
  # (the legacy -linux-amd64.rpm form is 9.x-and-older).
  # Stage the 1.5 GB RPM in /var/tmp (disk-backed) — AL2023 mounts /tmp as
  # tmpfs which is sized to half of RAM, too small on t3.small (~1 GB).
  provisioner "shell" {
    environment_vars = [
      "SPLUNK_VERSION=${var.splunk_version}",
      "SPLUNK_BUILD=${var.splunk_build}",
    ]
    inline = [
      "curl -fLo /var/tmp/splunk.rpm \"https://download.splunk.com/products/splunk/releases/$${SPLUNK_VERSION}/linux/splunk-$${SPLUNK_VERSION}-$${SPLUNK_BUILD}.x86_64.rpm\"",
    ]
  }

  provisioner "file" {
    source      = "files/splunk-install.sh"
    destination = "/tmp/splunk-install.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/splunk-install.sh",
      "sudo /tmp/splunk-install.sh",
    ]
  }

  # Final cleanup.
  provisioner "shell" {
    inline = [
      "sudo dnf clean all",
      "sudo rm -f /var/tmp/splunk.rpm /tmp/splunk-install.sh /tmp/splunk-limits.conf /tmp/cloudwatch-config.json",
      "sudo rm -rf /var/cache/dnf/*",
      # Reset cloud-init so the AMI re-runs first-boot user-data.
      "sudo cloud-init clean --logs --seed || true",
    ]
  }

  # Emit a manifest so CI can pick up the new AMI ID without screen-scraping
  # Packer's log output.
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
