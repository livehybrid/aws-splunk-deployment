        {
            "Sid": "DenyIncorrectEncryptionHeader",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${bucket_name}/*",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-server-side-encryption": [
                        "${disallowed_encryption}",
                        ""
                    ]
                }
            }
        }