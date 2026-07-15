data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"

      identifiers = [
        "ec2.amazonaws.com",
      ]
    }
  }
}

locals {
  iam_s3_read_only_actions = [
    "s3:GetObject",
    "s3:GetObjectVersion",
  ]

  iam_s3_put_actions = [
    "s3:PutObject",
    "s3:PutObjectAcl",
  ]

  iam_s3_read_write_actions = [
    "s3:ListMultipartUploadParts",
    "s3:AbortMultipartUpload",
    "s3:GetObject",
    "s3:GetObjectVersion",
    "s3:PutObject",
    "s3:PutObjectAcl",
    "s3:DeleteObject",
  ]

  iam_s3_list_bucket_actions = [
    "s3:ListBucket",
    "s3:ListBucketMultipartUploads",
  ]

  iam_s3_registry_resource_actions = [
    "s3:ListMultipartUploadParts",
    "s3:AbortMultipartUpload",
    "s3:GetObject",
    "s3:GetObjectVersion",
    "s3:PutObject",
    "s3:PutObjectAcl",
    "s3:PutObjectVersionAcl",
    "s3:DeleteObject",
  ]

  iam_kms_encrypt_decrypt_actions = [
    "kms:DescribeKey",
    "kms:GenerateDataKey*",
    "kms:Encrypt",
    "kms:ReEncrypt*",
    "kms:Decrypt",
  ]

  iam_kms_decrypt_actions = [
    "kms:DescribeKey",
    "kms:Decrypt",
  ]

  iam_kms_encrypt_actions = [
    "kms:DescribeKey",
    "kms:GenerateDataKey*",
    "kms:Encrypt",
    "kms:ReEncrypt*",
  ]

  sqs_process_actions = [
    "sqs:GetQueueAttributes",
    "sqs:ListQueues",
    "sqs:ReceiveMessage",
    "sqs:GetQueueUrl",
    "sqs:DeleteMessage",
  ]
}

