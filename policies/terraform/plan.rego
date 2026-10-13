# Guardrails evaluated against `terraform show -json plan.out` in CI, before
# any apply (works with conftest, or as a Spacelift plan policy).
#   conftest test --policy policies/terraform plan.json
package main

import rego.v1

managed := [rc | some rc in input.resource_changes; rc.mode == "managed"; not deleting(rc)]

deleting(rc) if rc.change.actions == ["delete"]

# --- IAM: least privilege, enforced again at the plan level -----------------

policy_docs contains [rc.address, json.unmarshal(rc.change.after.policy)] if {
	some rc in managed
	rc.type in {"aws_iam_policy", "aws_iam_role_policy"}
	is_string(rc.change.after.policy)
}

statements(doc) := doc.Statement if is_array(doc.Statement)

statements(doc) := [doc.Statement] if is_object(doc.Statement)

as_list(x) := x if is_array(x)

as_list(x) := [x] if is_string(x)

deny contains msg if {
	some [addr, doc] in policy_docs
	some st in statements(doc)
	st.Effect == "Allow"
	some a in as_list(st.Action)
	a in {"*", "iam:*"}
	msg := sprintf("%s: Allow on %q is never acceptable", [addr, a])
}

deny contains msg if {
	some [addr, doc] in policy_docs
	some st in statements(doc)
	st.Effect == "Allow"
	some a in as_list(st.Action)
	startswith(a, "iam:")
	not startswith(addr, "module.platform")
	msg := sprintf("%s: workload policies may not grant IAM actions (%s)", [addr, a])
}

# --- Data protection --------------------------------------------------------

deny contains msg if {
	some rc in managed
	rc.type == "aws_s3_bucket_public_access_block"
	some k in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]
	rc.change.after[k] == false
	msg := sprintf("%s: %s must stay true", [rc.address, k])
}

deny contains msg if {
	some rc in managed
	rc.type == "aws_db_instance"
	not rc.change.after.storage_encrypted
	msg := sprintf("%s: databases must be encrypted at rest", [rc.address])
}

deny contains msg if {
	some rc in managed
	rc.type == "aws_security_group_rule"
	rc.change.after.type == "ingress"
	"0.0.0.0/0" in rc.change.after.cidr_blocks
	rc.change.after.from_port != 443
	msg := sprintf("%s: only 443 may be open to the internet", [rc.address])
}

# --- Ownership --------------------------------------------------------------

taggable := {"aws_eks_cluster", "aws_db_instance", "aws_s3_bucket", "aws_dynamodb_table", "aws_sqs_queue", "aws_kms_key"}

warn contains msg if {
	some rc in managed
	rc.type in taggable
	tags := object.get(rc.change.after, "tags_all", {})
	not tags["ridgeline.dev/environment"]
	msg := sprintf("%s: missing ridgeline.dev/environment tag", [rc.address])
}
