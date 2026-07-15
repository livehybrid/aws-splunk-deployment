output "asg_id" {
  value = aws_autoscaling_group.splunk-asg.*.id
}

output "dns" {
  value = aws_route53_record.host_dns.*.fqdn
}

output "ip" {
  value = aws_eip.static_ip.*.public_ip
}

//output "e_ip" {
//  value = "${var.role == "heavy-forwarder" ? aws_eip.static_ip.*.public_ip : tolist([""])}"
//}