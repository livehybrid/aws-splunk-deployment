output "namespace" {
  value = local.namespace
}

output "smartstore_bucket" {
  value = data.aws_s3_bucket.smartstore.bucket
}

output "hints" {
  value = <<-EOT
    ${data.terraform_remote_state.eks.outputs.kubeconfig_command}
    kubectl get clustermanager,indexercluster,searchheadcluster,standalone,licensemanager,monitoringconsole -n ${local.namespace}
    ${var.enable_shc ? "kubectl port-forward -n ${local.namespace} svc/splunk-shc-search-head-service 8000:8000" : "kubectl port-forward -n ${local.namespace} svc/splunk-sh-standalone-service 8000:8000"}   # Splunk Web (admin / password from ${var.sok_secret_admin_password_id})
    ${var.sok_web_external_enabled ? join("\n", [for c, h in local.web_component_hosts : "open https://${h}   # ${c} UI via external ALB (admin / password from ${var.sok_secret_admin_password_id})"]) : "# external web disabled (set sok_web_external_enabled=true to expose an ALB)"}
  EOT
}

output "web_external_urls" {
  description = "Public UI URLs per exposed component when sok_web_external_enabled=true (else {}); includes hec when sok_hec_external_enabled."
  value = merge(
    { for c, h in local.web_component_hosts : c => "https://${h}" },
    local.hec_external_enabled ? { hec = "https://${local.hec_host}" } : {}
  )
}
