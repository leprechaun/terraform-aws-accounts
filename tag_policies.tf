# Standardizes casing for the same tag keys the provider's default_tags
# already sets (see providers.tf) — doesn't restrict values, since
# snacker-tracker will hold its own application resources with legitimately
# different Environment/Project/Component values than this repo's own
# "shared-infra" defaults.
#
# enforced_for makes these keys required-for-compliance (not
# creation-blocking — see README) on a starting set of common resource
# types (ec2:instance, ec2:volume, s3:bucket, rds:db, lambda:function).
# This is a known-valid subset from AWS's own tag-policy examples, not
# exhaustive — expand it once you see what's actually deployed and showing
# up (or not) in the compliance report.
#
# Requires TAG_POLICY in aws_organizations_organization.this's
# enabled_policy_types (see organization.tf) — without that, applying this
# policy fails.
locals {
  standard_tags_enforced_for = [
    "ec2:instance",
    "ec2:volume",
    "s3:bucket",
    "rds:db",
    "lambda:function",
  ]
}

resource "aws_organizations_policy" "standard_tags" {
  name        = "standard-tags"
  description = "Standardizes casing for Environment/ManagedBy/Repository/Project/Component tags."
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      Environment = {
        tag_key      = { "@@assign" = "Environment" }
      }
      ManagedBy = {
        tag_key      = { "@@assign" = "ManagedBy" }
      }
      Repository = {
        tag_key      = { "@@assign" = "Repository" }
      }
      Project = {
        tag_key      = { "@@assign" = "Project" }
      }
      Component = {
        tag_key      = { "@@assign" = "Component" }
      }
    }
  })
}

# Attached at the org root — applies to every account, including the
# management account, and automatically covers any account added later
# with no list to maintain here.
resource "aws_organizations_policy_attachment" "standard_tags" {
  policy_id = aws_organizations_policy.standard_tags.id
  target_id = aws_organizations_organization.this.roots[0].id
}
