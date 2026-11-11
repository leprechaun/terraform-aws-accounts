# CI roles for the site's own repo, which deploys a static site from S3
# through CloudFront (origin access control, an ACM certificate) under the
# site zone (dns.tf). Plan on any branch, read-only; apply only from its
# approval-gated prod environment.
#
# Nothing here names the domain, which stays secret: the origin bucket is
# scoped by the fixed prefix below, and records by the zone's ID.

locals {
  # The immutable sub form, as this account's repos use (see
  # modules/member-baseline). Pin the repo ID once the repo exists.
  site_repo = "leprechaun@355637/lmac-sh-site@*"

  # The origin bucket (and any others the site needs) must be named with this.
  site_bucket_prefix = "lmac-sh-site"

  # Same layout as the account's own stack, one level down.
  site_state_key = "member-accounts/lmac-sh/site/terraform.tfstate"

  site_github_roles = {
    site = {
      repo            = local.site_repo
      subjects        = ["environment:prod"]
      inline_policies = { deploy = data.aws_iam_policy_document.site_deploy.json }
    }

    site-plan = {
      repo        = local.site_repo
      subjects    = ["ref:refs/heads/*"]
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      inline_policies = {
        state = data.aws_iam_policy_document.site_state["site-plan"].json
      }
    }
  }
}

# The bucket is in the management account, so this is only half the grant;
# the other half is its bucket policy (terraform_state_bucket.tf there).
data "aws_iam_policy_document" "site_state" {
  for_each = {
    site      = ["s3:GetObject", "s3:PutObject"]
    site-plan = ["s3:GetObject"]
  }

  statement {
    sid       = "State"
    actions   = each.value
    resources = ["arn:aws:s3:::${module.baseline.state_bucket}/${local.site_state_key}"]
  }

  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${module.baseline.state_bucket}/${local.site_state_key}.tflock"]
  }

  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${module.baseline.state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${dirname(local.site_state_key)}/*"]
    }
  }
}

# No IAM at all: the site needs no roles of its own (no Lambda@Edge), so the
# role can't grant itself anything. CloudFront and ACM are account-wide since
# this account only hosts the site.
data "aws_iam_policy_document" "site_deploy" {
  source_policy_documents = [data.aws_iam_policy_document.site_state["site"].json]

  statement {
    sid     = "OriginBuckets"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${local.site_bucket_prefix}*",
      "arn:aws:s3:::${local.site_bucket_prefix}*/*",
    ]
  }

  # Distributions, origin access controls, cache and response headers
  # policies, functions, invalidations.
  statement {
    sid       = "CloudFront"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }

  # CloudFront only takes certificates from us-east-1.
  statement {
    sid       = "Certificates"
    actions   = ["acm:*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-east-1"]
    }
  }

  # Records in the site zone only; the zone itself is this stack's.
  statement {
    sid = "Records"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = [aws_route53_zone.site.arn]
  }

  statement {
    sid       = "FindZoneAndChanges"
    actions   = ["route53:GetChange", "route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

output "site_role_arn" {
  description = "The site repo's apply role, for its prod environment."
  value       = module.baseline.github_role_arns["site"]
}

output "site_plan_role_arn" {
  value = module.baseline.github_role_arns["site-plan"]
}
