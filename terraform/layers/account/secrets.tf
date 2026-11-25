# pass4symmkey
resource "random_string" "splunk_pass4Symmkey" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "splunk_pass4Symmkey" {
  name = var.sok_secret_pass4symmkey_id
}

resource "aws_secretsmanager_secret_version" "splunk_pass4Symmkey" {
  secret_id     = aws_secretsmanager_secret.splunk_pass4Symmkey.id
  secret_string = random_string.splunk_pass4Symmkey.result
}

# admin password
resource "random_string" "splunk_admin_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "splunk_admin_password" {
  name = var.sok_secret_admin_password_id
}

resource "aws_secretsmanager_secret_version" "splunk_admin_password" {
  secret_id     = aws_secretsmanager_secret.splunk_admin_password.id
  secret_string = random_string.splunk_admin_password.result
}


