###############################################################################
# SSM Patch Manager — Amazon Linux 2023 baseline + maintenance window.
###############################################################################

resource "aws_iam_service_linked_role" "ssm" {
  aws_service_name = "ssm.amazonaws.com"
  description      = "Service Linked Role for Maintenance Windows to execute tasks"
}

resource "aws_ssm_maintenance_window" "patching" {
  name     = "splunk-patching"
  schedule = "cron(0 2 ? * TUE *)"
  duration = 3
  cutoff   = 1
}

resource "aws_ssm_patch_baseline" "al2023" {
  name             = "patch-baseline-al2023"
  description      = "Patch baseline for Amazon Linux 2023"
  operating_system = "AMAZON_LINUX_2023"

  global_filter {
    key    = "CLASSIFICATION"
    values = ["Security", "Bugfix"]
  }

  approval_rule {
    approve_after_days = 7

    patch_filter {
      key    = "SEVERITY"
      values = ["Critical", "Important"]
    }
  }
}

resource "aws_resourcegroups_group" "all" {
  name = "all-hosts"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::EC2::Instance"]
      TagFilters = [{
        Key    = "environment"
        Values = [var.environment]
      }]
    })
  }
}
