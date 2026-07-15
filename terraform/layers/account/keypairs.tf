###############################################################################
# SSH keypair for ops break-glass access. Day-to-day access is via SSM Session
# Manager — this keypair exists only for AMI-level recovery.
###############################################################################

resource "tls_private_key" "ops" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

resource "aws_key_pair" "ops" {
  key_name   = "ops"
  public_key = tls_private_key.ops.public_key_openssh
}

resource "aws_secretsmanager_secret" "ops_public_key" {
  name = "/ssh-keys/ops.pub"
}

resource "aws_secretsmanager_secret_version" "ops_public_key" {
  secret_id     = aws_secretsmanager_secret.ops_public_key.id
  secret_string = tls_private_key.ops.public_key_openssh
}

resource "aws_secretsmanager_secret" "ops_private_key" {
  name = "/ssh-keys/ops"
}

resource "aws_secretsmanager_secret_version" "ops_private_key" {
  secret_id     = aws_secretsmanager_secret.ops_private_key.id
  secret_string = tls_private_key.ops.private_key_pem
}
