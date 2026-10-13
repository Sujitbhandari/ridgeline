package main

import rego.v1

policy(doc) := {"resource_changes": [{
	"address": "aws_iam_policy.grant",
	"mode": "managed",
	"type": "aws_iam_policy",
	"change": {"actions": ["create"], "after": {"policy": json.marshal(doc)}},
}]}

test_wildcard_denied if {
	count(deny) > 0 with input as policy({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})
}

test_iam_in_workload_policy_denied if {
	some msg in deny with input as policy({"Statement": [{"Effect": "Allow", "Action": ["iam:PassRole"], "Resource": "*"}]})
	contains(msg, "may not grant IAM")
}

test_least_privilege_allowed if {
	count(deny) == 0 with input as policy({"Statement": [{"Effect": "Allow", "Action": ["dynamodb:GetItem"], "Resource": ["arn:aws:dynamodb:us-east-1:1:table/x"]}]})
}

test_public_bucket_denied if {
	count(deny) > 0 with input as {"resource_changes": [{
		"address": "aws_s3_bucket_public_access_block.b",
		"mode": "managed",
		"type": "aws_s3_bucket_public_access_block",
		"change": {"actions": ["create"], "after": {"block_public_acls": true, "block_public_policy": false, "ignore_public_acls": true, "restrict_public_buckets": true}},
	}]}
}
