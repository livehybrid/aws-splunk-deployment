# Consumed by the sok layer via terraform_remote_state (key eks/terraform.tfstate).
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider" {
  description = "OIDC issuer URL (no scheme), IRSA trust-policy conditions key off this."
  value       = module.eks.oidc_provider
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA. Module v21 no longer creates this; we own it (eks.tf). The sok layer's Splunk IRSA trust policies read this via remote state."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

# Auto Scaling Group names backing the managed node groups. The sok layer alarms
# on CPUCreditBalance for the burstable (t3) nodes off these (NFR-2).
output "node_group_autoscaling_group_names" {
  description = "ASG names created by the EKS managed node groups (one per group)."
  value       = module.eks.eks_managed_node_groups_autoscaling_group_names
}

output "namespace" {
  description = "Namespace holding the operator and all Splunk CRs."
  value       = var.sok_namespace
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile ${var.profile}"
}
