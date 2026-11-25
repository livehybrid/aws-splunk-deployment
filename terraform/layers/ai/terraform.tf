###############################################################################
# AI layer: the Splunk AI tier on the SOK cluster.
#
# Apply order: account -> eks -> sok -> ai. Destroy in reverse (ai first).
#
#   account  artifacts bucket for model weights (ai.tf), persistent
#   eks      a GPU node group (eks_node_groups entry with gpu = true)
#   sok      cert-manager (shared with private-CA TLS) and the ALB controller
#   ai       NVIDIA device plugin, Splunk AI Operator, AIPlatform
#
# Own state key (never reuse another layer's): ai/terraform.tfstate.
# Everything here is gated on var.ai_tier_enabled; with it false this layer
# plans empty. See docs/ai-tier.md.
###############################################################################

terraform {
  backend "s3" {
    key     = "ai/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
