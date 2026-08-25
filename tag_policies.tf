# Standardizes casing for the same tag keys the provider's default_tags
# already sets (see providers.tf) — doesn't restrict values, since
# snacker-tracker will hold its own application resources with legitimately
# different Environment/Project/Component values than this repo's own
# "shared-infra" defaults.
#
# report_required_tag_for makes these keys required-for-compliance (not
# creation-blocking — see README). The field is named
# report_required_tag_for, not enforced_for — the latter is a real field,
# but it's for a different feature (Basic Compliance Rules: blocking
# resource creation on bad tag *values*), not required tag *keys*, and
# using it here silently produces MalformedPolicyDocumentException (found
# the hard way, before checking the actual Terraform AWS provider docs).
#
# This is NOT the full list of resource types AWS's tag-policy service
# supports (443, as of the Terraform AWS provider's own cross-reference
# table) — that's a hard wall, not a choice: AWS caps a tag policy document
# at 10,000 characters total, and the full list alone is already ~11,400
# characters for a *single* tag key, before the other four keys or the
# per-tag JSON wrapper are even counted (confirmed against
# ConstraintViolationException, then against AWS's own quota docs). There's
# no wildcard for "every service" either — AWS's docs explicitly say a
# wildcard can't specify all services, only ALL_SUPPORTED per named service.
#
# So this is a curated, generously-bounded list instead: every service
# either of the two application repos (snacker-tracker-aws,
# reporter-serverless) or this repo actually uses, expressed as
# "service:ALL_SUPPORTED" wherever that's valid (confirmed against AWS's
# supported-resources-enforcement page, not guessed) — one entry covers
# every resource type that service has, present or future. A few gaps,
# confirmed against that same page, not oversights:
#  - apigateway has NO resource types that support required-tag-keys
#    reporting mode at all yet (every row is "No") — despite
#    reporter-serverless using API Gateway, there's currently nothing to
#    enforce here. Nothing to fix; AWS just hasn't added support.
#  - logs (CloudWatch Logs) has no ALL_SUPPORTED entry at all — listed
#    individually below instead, covering every logs:* type that does
#    support it.
#  - iam:role and iam:user report only via IaC warnings (Terraform/
#    CloudFormation/Pulumi plan-time), not the org-wide compliance report
#    — still worth having active for the Terraform-side check.
# Add more service entries here as new services get used elsewhere in
# this org, checking the same supported-resources page first.
#
# Requires TAG_POLICY in aws_organizations_organization.this's
# enabled_policy_types (see organization.tf) — without that, applying this
# policy fails.
locals {
  standard_tags_report_required_for = [
    "ec2:ALL_SUPPORTED",           # snacker-tracker-aws, terraform-aws-accounts
    "s3:ALL_SUPPORTED",            # all three repos
    "lambda:ALL_SUPPORTED",        # reporter-serverless
    "rds:ALL_SUPPORTED",           # not in use yet, cheap to have ready
    "dynamodb:ALL_SUPPORTED",      # not in use yet, cheap to have ready
    "sqs:ALL_SUPPORTED",           # reporter-serverless
    "sns:ALL_SUPPORTED",           # not in use yet, cheap to have ready
    "events:ALL_SUPPORTED",        # reporter-serverless (EventBridge)
    "firehose:ALL_SUPPORTED",      # reporter-serverless
    "ecr:ALL_SUPPORTED",           # snacker-tracker-aws
    "iam:ALL_SUPPORTED",           # all three repos
    "cloudtrail:ALL_SUPPORTED",    # terraform-aws-accounts
    "acm:ALL_SUPPORTED",           # reporter-serverless (custom domain cert)
    "cloudfront:ALL_SUPPORTED",    # reporter-serverless (edge-optimized API GW)
    "route53:ALL_SUPPORTED",       # snacker-tracker-aws, reporter-serverless
    "organizations:ALL_SUPPORTED", # terraform-aws-accounts
    "kms:ALL_SUPPORTED",           # not in use yet, cheap to have ready
    "bcm-data-exports:export",     # terraform-aws-accounts; no ALL_SUPPORTED for this service
    "logs:log-group",              # no ALL_SUPPORTED for logs; listed individually
    "logs:delivery-destination",
    "logs:destination",
    "logs:delivery-source",
    "logs:anomaly-detector",
    "logs:delivery",
  ]
}

resource "aws_organizations_policy" "standard_tags" {
  name        = "standard-tags"
  description = "Standardizes casing for Environment/ManagedBy/Repository/Project/Component tags."
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      Environment = {
        tag_key                 = { "@@assign" = "Environment" }
        report_required_tag_for = { "@@assign" = local.standard_tags_report_required_for }
      }
      ManagedBy = {
        tag_key                 = { "@@assign" = "ManagedBy" }
        report_required_tag_for = { "@@assign" = local.standard_tags_report_required_for }
      }
      Repository = {
        tag_key                 = { "@@assign" = "Repository" }
        report_required_tag_for = { "@@assign" = local.standard_tags_report_required_for }
      }
      Project = {
        tag_key                 = { "@@assign" = "Project" }
        report_required_tag_for = { "@@assign" = local.standard_tags_report_required_for }
      }
      Component = {
        tag_key                 = { "@@assign" = "Component" }
        report_required_tag_for = { "@@assign" = local.standard_tags_report_required_for }
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
