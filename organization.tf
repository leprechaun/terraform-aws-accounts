# The organization already exists (the existing sub-account is already a
# member of it) — this resource must be imported, not created. See README.

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # cloudtrail.amazonaws.com: required before a trail can be made an
  # organization trail (CloudTrailAccessNotEnabledException without it).
  # tagpolicies.tag.amazonaws.com: required for tag policies to actually
  # apply — a separate prerequisite from enabled_policy_types below (that
  # one enables the TAG_POLICY policy *type* on the root; this one grants
  # the tag policies service itself trusted access to the org).
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "tagpolicies.tag.amazonaws.com",
  ]

  # Must list every policy type actually enabled on the root, or Terraform
  # treats anything missing here as drift and tries to disable it —
  # TAG_POLICY was enabled via `aws organizations enable-policy-type`
  # (this resource has no argument that triggers that call itself, only one
  # that reflects/enforces the desired end state).
  enabled_policy_types = ["TAG_POLICY"]
}
