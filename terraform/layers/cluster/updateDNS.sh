make terraform-clean
make terraform-rm object=aws_route53_record.splunk_routing env=$1
make terraform env=$1 args="-target aws_route53_record.splunk_routing -target data.terraform_remote_state.account -target data.terraform_remote_state.iam"