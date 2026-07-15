        {
			"Sid": "RequireSpecificKey",
			"Effect": "Deny",
			"Principal": "*",
			"Action": "s3:PutObject",
			"Resource": "arn:aws:s3:::${bucket_name}/*",
			"Condition": {
				"StringNotLike": {
					"s3:x-amz-server-side-encryption-aws-kms-key-id":
					["${required_kms_arn}",""]
				}
			}
		}
        