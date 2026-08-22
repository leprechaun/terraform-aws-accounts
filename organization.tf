# The organization already exists (the existing sub-account is already a
# member of it) — this resource must be imported, not created. See README.

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"
}
