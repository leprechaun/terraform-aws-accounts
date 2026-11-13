# CI roles for the site's own repo, which deploys a private static site from
# S3 through CloudFront (origin access control, an ACM certificate) under the
# site zone (dns.tf), behind a Cognito user pool checked by a Lambda@Edge
# function. Plan on any branch, read-only; apply only from its
# approval-gated prod environment.
#
# Nothing here names the domain, which stays secret: the site's buckets,
# functions and roles are scoped by the fixed prefixes below, and records by
# the zone's ID.

locals {
  # The immutable sub form, as this account's repos use (see
  # modules/member-baseline).
  site_repo = "leprechaun@355637/lmac-sh-site@1454451414"

  # The site's buckets must be named with this.
  site_prefix = "lmac-sh-site"

  # And its functions and their roles with this, as the stack named them
  # before it moved here from the management account (private-website-auth).
  site_runtime_prefix = "private-website"
  site_boundary       = "${local.site_runtime_prefix}-auth-boundary"

  # Lambda@Edge functions have to be created in us-east-1.
  site_function_arn = "arn:aws:lambda:us-east-1:${local.account_id}:function:${local.site_runtime_prefix}-*"
  site_role_arn     = "arn:aws:iam::${local.account_id}:role/${local.site_runtime_prefix}-*"

  # Same layout as the account's own stack, one level down.
  site_state_key = "member-accounts/lmac-sh/site/terraform.tfstate"

  # CloudFront's access logs go to the management account's central bucket,
  # through this account's delivery destination there. Its delivery sources
  # must be named with one of these, the sites' own names rather than
  # site_prefix.
  site_log_source_prefixes     = ["public-website", "private-website"]
  site_access_logs_policy      = "github-site-access-logs"
  site_access_logs_destination = "arn:aws:logs:us-east-1:${local.management_account_id}:delivery-destination:access-logs-lmac-sh"

  site_github_roles = {
    site = {
      repo            = local.site_repo
      subjects        = ["environment:prod"]
      inline_policies = { deploy = data.aws_iam_policy_document.site_deploy.json }
      # Managed, not another inline policy: a role's inline policies share
      # one 10,240 character limit, and the deploy policy is most of it.
      managed_policies = [local.site_access_logs_policy]
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

  site_managed_policies = {
    (local.site_access_logs_policy) = {
      description = "CloudFront access log delivery for lmac-sh-site's CI: its own delivery sources and deliveries, to this account's destination in the management account."
      policy      = data.aws_iam_policy_document.site_access_logs.json
    }

    (local.site_boundary) = {
      description = "Permissions boundary for the roles lmac-sh-site's CI creates (the Lambda@Edge auth function's): logs only."
      policy      = data.aws_iam_policy_document.site_runtime_boundary.json
    }
  }
}

# The cap on every role the site's CI creates, whatever policies it gives
# them (AWSLambdaBasicExecutionRole, for the auth function): the deploy role
# can only create or change roles carrying it. The auth function checks
# Cognito's tokens against its public keys and needs no AWS access but its
# logs. Lambda@Edge writes those in whichever region served the request, as
# /aws/lambda/us-east-1.<function>.
data "aws_iam_policy_document" "site_runtime_boundary" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:${local.account_id}:log-group:/aws/lambda/*"]
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

# IAM only on the site's own roles, and only while they carry the runtime
# boundary, so the role can't grant itself or anything else more than that.
# CloudFront, ACM and Cognito are account-wide since this account only hosts
# the site.
data "aws_iam_policy_document" "site_deploy" {
  source_policy_documents = [data.aws_iam_policy_document.site_state["site"].json]

  statement {
    sid     = "OriginBuckets"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${local.site_prefix}*",
      "arn:aws:s3:::${local.site_prefix}*/*",
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

  # The user pool, its clients, groups and domain. A custom domain also needs
  # the certificate (above) and an alias record (Records).
  statement {
    sid       = "Cognito"
    actions   = ["cognito-idp:*"]
    resources = ["*"]
  }

  # Functions, their versions, and replicating them to CloudFront's edges.
  # Lambda@Edge only in us-east-1.
  statement {
    sid       = "Functions"
    actions   = ["lambda:*"]
    resources = [local.site_function_arn, "${local.site_function_arn}:*"]
  }

  statement {
    sid       = "FunctionLogs"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:*:${local.account_id}:log-group:/aws/lambda/*${local.site_runtime_prefix}-*"]
  }

  statement {
    sid       = "DescribeLogs"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid = "Roles"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
      "iam:DetachRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = [local.site_role_arn]
  }

  # Creating a role or adding to what it may do only with the boundary on,
  # so attaching even AdministratorAccess gets no further than it. No
  # DeleteRolePermissionsBoundary, so it can't come off.
  statement {
    sid = "BoundedRoles"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.site_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [module.baseline.managed_policy_arns[local.site_boundary]]
    }
  }

  statement {
    sid       = "PassRoles"
    actions   = ["iam:PassRole"]
    resources = [local.site_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # Lambda@Edge's replicator role, created the first time a function is
  # attached to a distribution.
  statement {
    sid       = "EdgeReplicator"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/replicator.lambda.amazonaws.com/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["replicator.lambda.amazonaws.com"]
    }
  }
}

output "site_role_arn" {
  description = "The site repo's apply role, for its prod environment."
  value       = module.baseline.github_role_arns["site"]
}

output "site_runtime_boundary_arn" {
  description = "Set as permissions_boundary on every role the site's stack creates."
  value       = module.baseline.managed_policy_arns[local.site_boundary]
}

output "site_plan_role_arn" {
  value = module.baseline.github_role_arns["site-plan"]
}

# CloudFront standard logging v2 for the site (cloudfront:* above already
# covers cloudfront:AllowVendedLogDeliveryForResource). The delivery
# destination is the management account's, with a policy there that lets
# this account create a delivery to it, so there are no destination
# permissions here: only the delivery source and the delivery. Delivery IDs
# are generated, so deliveries can't be scoped by name. These are all
# us-east-1 whatever region the bucket is in.
data "aws_iam_policy_document" "site_access_logs" {
  statement {
    sid = "Deliveries"
    actions = [
      "logs:PutDeliverySource", "logs:GetDeliverySource", "logs:DeleteDeliverySource",
      "logs:CreateDelivery", "logs:GetDelivery", "logs:DeleteDelivery", "logs:UpdateDeliveryConfiguration",
      "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
    ]
    resources = concat(
      [for prefix in local.site_log_source_prefixes : "arn:aws:logs:us-east-1:${local.account_id}:delivery-source:${prefix}-*"],
      ["arn:aws:logs:us-east-1:${local.account_id}:delivery:*"],
    )
  }

  # Creating a delivery names the destination too.
  statement {
    sid       = "DeliverToCentralDestination"
    actions   = ["logs:CreateDelivery"]
    resources = [local.site_access_logs_destination]
  }

  statement {
    sid = "ReadDeliveries"
    actions = [
      "logs:DescribeDeliverySources", "logs:DescribeDeliveryDestinations", "logs:DescribeDeliveries",
      "logs:DescribeConfigurationTemplates", "logs:DescribeResourcePolicies",
    ]
    resources = ["*"]
  }
}
