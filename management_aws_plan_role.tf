# Read-only GitHub Actions role for `terraform plan` on the management-aws
# stacks, for the same reason as github_actions_plan_role.tf: plan runs on every
# branch and should never hold credentials capable of changing anything. Only
# aws_iam_role.management_aws_github_actions can apply.

locals {
  management_aws_github_actions_plan_role_name = "management-aws-github-actions-plan"
}

data "aws_iam_policy_document" "management_aws_github_actions_plan_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any branch, with no `environment:` set. See the apply role for why both
    # sub claim forms are listed.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun/${local.management_aws_github_repo}:ref:refs/heads/*",
        "repo:leprechaun@355637/${local.management_aws_github_repo}@*:ref:refs/heads/*",
      ]
    }
  }
}

resource "aws_iam_role" "management_aws_github_actions_plan" {
  name               = local.management_aws_github_actions_plan_role_name
  assume_role_policy = data.aws_iam_policy_document.management_aws_github_actions_plan_assume_role.json

  tags = {
    Project   = "management-aws"
    Component = "deploy"
  }

  # Same ordering as the apply role.
  depends_on = [aws_iam_role_policy.github_actions]
}

data "aws_iam_policy_document" "management_aws_github_actions_plan_permissions" {
  # This state holds the Cognito client secrets, so anything that can assume
  # this role can read them, despite the role being read-only.
  statement {
    sid     = "TerraformStateRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::lmacguire-terraform/management-aws/*/terraform.tfstate",
      "arn:aws:s3:::lmacguire-terraform/management-aws/*/terraform.tfstate.tflock",
    ]
  }

  # Plan takes and releases the native S3 lock, but never writes the state.
  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/management-aws/*/terraform.tfstate.tflock"]
  }

  # `terraform init` lists "env:/" to enumerate workspaces, even when only
  # default is used.
  statement {
    sid       = "TerraformStateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::lmacguire-terraform"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["management-aws/*", "env:/*"]
    }
  }

  statement {
    sid       = "Route53ZoneList"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }

  statement {
    sid    = "Route53ZoneRead"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["arn:aws:route53:::hostedzone/${aws_route53_zone.personal_domain.zone_id}"]
  }

  statement {
    sid       = "AcmRead"
    effect    = "Allow"
    actions   = ["acm:DescribeCertificate", "acm:ListTagsForCertificate"]
    resources = ["arn:aws:acm:${local.management_aws_global_region}:${var.owner_account_id}:certificate/*"]
  }

  statement {
    sid    = "CognitoUserPoolRead"
    effect = "Allow"
    actions = [
      "cognito-idp:DescribeUserPool",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:GetLogDeliveryConfiguration",
      "cognito-idp:GetUserPoolMfaConfig",
      "cognito-idp:ListTagsForResource",
      "cognito-idp:ListUserPoolClients",
    ]
    resources = ["arn:aws:cognito-idp:${local.management_aws_cognito_region}:${var.owner_account_id}:userpool/*"]
  }

  statement {
    sid       = "CognitoAccountLevelRead"
    effect    = "Allow"
    actions   = ["cognito-idp:DescribeUserPoolDomain", "cognito-idp:ListUserPools"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.management_aws_cognito_region]
    }
  }

  statement {
    sid       = "CloudFrontRead"
    effect    = "Allow"
    actions   = ["cloudfront:GetDistribution", "cloudfront:ListTagsForResource"]
    resources = ["arn:aws:cloudfront::${var.owner_account_id}:distribution/*"]
  }

  # The website looks up a managed cache policy by name, which lists policies to
  # find the ID and then reads it.
  statement {
    sid       = "CloudFrontCachePolicyRead"
    effect    = "Allow"
    actions   = ["cloudfront:GetCachePolicy", "cloudfront:ListCachePolicies"]
    resources = ["arn:aws:cloudfront::${var.owner_account_id}:cache-policy/*"]
  }

  # s3:Get*/List* for the same reason as CloudTrailAndCostExportBucketsRead in
  # github_actions_plan_role.tf, but on the bucket ARNs only, which excludes
  # object actions.
  statement {
    sid       = "BucketsRead"
    effect    = "Allow"
    actions   = ["s3:Get*", "s3:List*"]
    resources = ["arn:aws:s3:::lmacguire-ses-incoming", "arn:aws:s3:::${var.personal_domain_name}"]
  }

  # Delivery names embed generated IDs, and the classic *LogDelivery and resource
  # policy actions don't support resource-level scoping.
  statement {
    sid    = "LogsRead"
    effect = "Allow"
    actions = [
      "logs:DescribeDeliveries",
      "logs:DescribeDeliveryDestinations",
      "logs:DescribeDeliverySources",
      "logs:DescribeLogGroups",
      "logs:DescribeResourcePolicies",
      "logs:GetDelivery",
      "logs:GetDeliveryDestination",
      "logs:GetDeliverySource",
      "logs:GetLogDelivery",
      "logs:ListLogDeliveries",
      "logs:ListTagsForResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.management_aws_cognito_region, local.management_aws_global_region]
    }
  }

  statement {
    sid    = "SesRead"
    effect = "Allow"
    actions = [
      "ses:DescribeActiveReceiptRuleSet",
      "ses:DescribeReceiptRule",
      "ses:DescribeReceiptRuleSet",
      "ses:GetIdentityDkimAttributes",
      "ses:GetIdentityVerificationAttributes",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.management_aws_ses_region]
    }
  }

  statement {
    sid       = "KbankQueueRead"
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueueTags"]
    resources = ["arn:aws:sqs:${local.management_aws_ses_region}:${var.owner_account_id}:ses-incoming-notifications-prod"]
  }
}

resource "aws_iam_role_policy" "management_aws_github_actions_plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.management_aws_github_actions_plan.id
  policy = data.aws_iam_policy_document.management_aws_github_actions_plan_permissions.json
}
