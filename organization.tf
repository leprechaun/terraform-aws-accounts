# The organization already exists (the existing sub-account is already a
# member of it) — this resource must be imported, not created. See README.

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # Required before a trail can be made an organization trail — without
  # this, CloudTrail rejects is_organization_trail = true (and possibly any
  # UpdateTrail call on an org trail) with CloudTrailAccessNotEnabledException.
  aws_service_access_principals = ["cloudtrail.amazonaws.com"]
}
