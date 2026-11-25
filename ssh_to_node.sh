INSTANCEID=$(aws ec2 describe-instances \
    --filters 'Name=tag:aws:eks:cluster-name,Values=splunk-sok-dev' \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)
aws ec2-instance-connect send-ssh-public-key --instance-id $INSTANCEID --instance-os-user ec2-user --ssh-public-key file://~/.ssh/id_ed25519.pub
ssh -D 1080 ec2-user@$INSTANCEID
