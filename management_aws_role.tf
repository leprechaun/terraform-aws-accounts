# GitHub Actions deploy role for the management-aws stacks: the Cognito auth
# pool, SES inbound email and the static website. Its pipeline runs `terraform
# apply` on each of them, so these permissions mirror what they manage.

locals {
  management_aws_github_actions_role_name = "management-aws-github-actions"
  management_aws_github_repo              = "terraform-aws-management"
  management_aws_cognito_region           = "ap-southeast-1"
  management_aws_ses_region               = "eu-west-1"
  # CloudFront, its ACM certificates and its log delivery.
  management_aws_global_region = "us-east-1"
}

data "aws_iam_policy_document" "management_aws_github_actions_assume_role" {
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

    # Only runs on master. That pipeline's jobs don't set `environment:`, so
    # their claim is ref-scoped. Both sub claim forms are listed because this
    # repo's use_immutable_subject setting hasn't been confirmed; drop whichever
    # one GET /repos/OWNER/REPO/actions/oidc/customization/sub says doesn't
    # apply, and pin the repo ID if it's the immutable form.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun/${local.management_aws_github_repo}:ref:refs/heads/master",
        "repo:leprechaun@355637/${local.management_aws_github_repo}@*:ref:refs/heads/master",
      ]
    }
  }
}

resource "aws_iam_role" "management_aws_github_actions" {
  name               = local.management_aws_github_actions_role_name
  assume_role_policy = data.aws_iam_policy_document.management_aws_github_actions_assume_role.json

  tags = {
    Project   = "management-aws"
    Component = "deploy"
  }

  # Same ordering as the kbank role: apply needs its
  # ManageManagementAwsGithubActionsRole statement before it can create this.
  depends_on = [aws_iam_role_policy.github_actions]
}

data "aws_iam_policy_document" "management_aws_github_actions_deploy" {
  # One state per stack: management-aws/<stack>/terraform.tfstate.
  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/management-aws/*/terraform.tfstate"]
  }

  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
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

  # The aws_route53_zone data source, which all three stacks look up by name.
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

  # The domain comes from the sensitive variable, so it stays out of this repo.
  # `_*` covers ACM validation and the SES verification record.
  statement {
    sid       = "Route53RecordWrite"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${aws_route53_zone.personal_domain.zone_id}"]

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values = [
        var.personal_domain_name,
        "www.${var.personal_domain_name}",
        "auth.${var.personal_domain_name}",
        "garbage.${var.personal_domain_name}",
        "_*.${var.personal_domain_name}",
        "*._domainkey.${var.personal_domain_name}",
      ]
    }
  }

  statement {
    sid       = "Route53Change"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  # Neither of these supports resource-level scoping.
  statement {
    sid       = "AcmRequest"
    effect    = "Allow"
    actions   = ["acm:RequestCertificate", "acm:ListCertificates"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.management_aws_global_region]
    }
  }

  statement {
    sid    = "AcmCertificate"
    effect = "Allow"
    actions = [
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:ListTagsForCertificate",
      "acm:RemoveTagsFromCertificate",
    ]
    resources = ["arn:aws:acm:${local.management_aws_global_region}:${var.owner_account_id}:certificate/*"]
  }

  # Pool management only: no Admin* user actions, so the pipeline can't create
  # users or reset passwords. DescribeUserPoolClient does return client secrets,
  # which Terraform needs and also stores in this stack's state.
  statement {
    sid    = "CognitoUserPool"
    effect = "Allow"
    actions = [
      "cognito-idp:AddCustomAttributes",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:CreateUserPoolDomain",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:DeleteUserPoolDomain",
      "cognito-idp:DescribeUserPool",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:GetLogDeliveryConfiguration",
      "cognito-idp:GetUserPoolMfaConfig",
      "cognito-idp:ListTagsForResource",
      "cognito-idp:ListUserPoolClients",
      "cognito-idp:SetLogDeliveryConfiguration",
      "cognito-idp:SetUserPoolMfaConfig",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
      "cognito-idp:UpdateUserPool",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:UpdateUserPoolDomain",
    ]
    resources = ["arn:aws:cognito-idp:${local.management_aws_cognito_region}:${var.owner_account_id}:userpool/*"]
  }

  # None of these act on an existing pool ARN.
  statement {
    sid    = "CognitoAccountLevel"
    effect = "Allow"
    actions = [
      "cognito-idp:CreateUserPool",
      "cognito-idp:DescribeUserPoolDomain",
      "cognito-idp:ListUserPools",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.management_aws_cognito_region]
    }
  }

  # Custom domains on a user pool are backed by a CloudFront distribution that
  # Cognito owns, so there's no ARN in this account to scope to.
  statement {
    sid       = "CloudFrontUpdate"
    effect    = "Allow"
    actions   = ["cloudfront:UpdateDistribution"]
    resources = ["*"]
  }

  statement {
    sid    = "CloudFrontDistribution"
    effect = "Allow"
    actions = [
      "cloudfront:AllowVendedLogDeliveryForResource",
      "cloudfront:CreateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:ListTagsForResource",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
    ]
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

  # The website's standard logging target, which is also the CloudTrail bucket.
  # Read-only on purpose: this role shouldn't be able to change who can write
  # to or read audit logs.
  statement {
    sid       = "CloudFrontLogBucketAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = ["arn:aws:s3:::lmacguire-aws-logs"]
  }

  # s3:* for the same reason as CloudTrailAndCostExportBuckets in
  # github_oidc.tf, but on the bucket ARNs only, which excludes object actions.
  # That isn't a hard boundary: s3:PutBucketPolicy could grant object access.
  statement {
    sid       = "Buckets"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::lmacguire-ses-incoming", "arn:aws:s3:::${var.personal_domain_name}"]
  }

  statement {
    sid    = "LogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteRetentionPolicy",
      "logs:ListTagsForResource",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = [
      "arn:aws:logs:${local.management_aws_cognito_region}:${var.owner_account_id}:log-group:/aws/vendedlogs/cognito/*",
      "arn:aws:logs:${local.management_aws_global_region}:${var.owner_account_id}:log-group:cloudfront-*",
    ]
  }

  # Vended log delivery for the Cognito pool and the CloudFront distribution.
  # Delivery names embed generated IDs, and the classic *LogDelivery and resource
  # policy actions don't support resource-level scoping.
  statement {
    sid    = "LogDelivery"
    effect = "Allow"
    actions = [
      "logs:CreateDelivery",
      "logs:CreateLogDelivery",
      "logs:DeleteDelivery",
      "logs:DeleteDeliveryDestination",
      "logs:DeleteDeliverySource",
      "logs:DeleteLogDelivery",
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
      "logs:PutDeliveryDestination",
      "logs:PutDeliverySource",
      "logs:PutResourcePolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:UpdateDeliveryConfiguration",
      "logs:UpdateLogDelivery",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.management_aws_cognito_region, local.management_aws_global_region]
    }
  }

  # These SES actions don't support resource-level scoping.
  statement {
    sid    = "Ses"
    effect = "Allow"
    actions = [
      "ses:CreateReceiptRule",
      "ses:CreateReceiptRuleSet",
      "ses:DeleteIdentity",
      "ses:DeleteReceiptRule",
      "ses:DeleteReceiptRuleSet",
      "ses:DescribeActiveReceiptRuleSet",
      "ses:DescribeReceiptRule",
      "ses:DescribeReceiptRuleSet",
      "ses:GetIdentityDkimAttributes",
      "ses:GetIdentityVerificationAttributes",
      "ses:SetActiveReceiptRuleSet",
      "ses:UpdateReceiptRule",
      "ses:VerifyDomainDkim",
      "ses:VerifyDomainIdentity",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.management_aws_ses_region]
    }
  }

  # The SES stack only looks this queue up: it belongs to the kbank pipeline.
  statement {
    sid       = "KbankQueueRead"
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueueTags"]
    resources = ["arn:aws:sqs:${local.management_aws_ses_region}:${var.owner_account_id}:ses-incoming-notifications-prod"]
  }
}

resource "aws_iam_role_policy" "management_aws_github_actions_deploy" {
  name   = "deploy"
  role   = aws_iam_role.management_aws_github_actions.id
  policy = data.aws_iam_policy_document.management_aws_github_actions_deploy.json
}
