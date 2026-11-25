output "ep_namespace" {
  description = "Namespace the Edge Processor releases run in."
  value       = local.enabled ? local.namespace : ""
}

output "ep_nlb_hostnames" {
  description = "NLB DNS name per processor. Point forwarders (S2S), HEC clients and syslog senders here, or at ep_hostnames."
  value       = { for k, s in kubernetes_service_v1.nlb : k => s.status[0].load_balancer[0].ingress[0].hostname }
}

output "ep_hostnames" {
  description = "Route53 name per processor, for entries that set a hostname."
  value       = { for k, r in aws_route53_record.ep : k => r.fqdn }
}

output "ep_receivers" {
  description = "Receiver ports exposed on every processor's NLB. They must match the control plane's shared settings."
  value       = local.enabled ? { for r in local.receivers : r.name => "${r.port}/${r.protocol}" } : {}
}

output "next_steps" {
  description = "Commands that show whether each release came up (the apply does not wait; see main.tf)."
  value = local.enabled ? join("\n", flatten([
    for k in keys(local.processors) : [
      "# ${k}",
      "kubectl -n ${local.namespace} get job ep-${k}-generate-principal-job",
      "kubectl -n ${local.namespace} logs job/ep-${k}-generate-principal-job",
      "kubectl -n ${local.namespace} get pods -l app.kubernetes.io/instance=ep-${k}",
      "kubectl -n ${local.namespace} get svc ep-${k}-nlb",
    ]
  ])) : ""
}
