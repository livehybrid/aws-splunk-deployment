###############################################################################
# EP layer: Splunk Edge Processor instances on the SOK cluster.
#
# Apply order: account -> eks -> sok -> ep. Destroy in reverse (ep first: its
# NLBs belong to the ALB controller the sok layer installs, and only that
# controller can remove them).
#
#   sok  the ALB controller (NLBs) and the splunk-gp3-ext4 StorageClass
#   ep   one splunk/edge-processor release + NLB per entry in ep_processors
#
# The control plane (Splunk Cloud, or a Splunk Enterprise 10.0+ data management
# control plane) is NOT deployed here. Its Kubernetes install command supplies
# the TENANT, GROUP_ID and TOKEN this layer takes as inputs.
#
# Own state key (never reuse another layer's): ep/terraform.tfstate.
# Everything here is gated on var.ep_enabled; with it false this layer plans
# empty. See docs/edge-processor.md.
###############################################################################

terraform {
  backend "s3" {
    key     = "ep/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
