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
        "login.${var.personal_domain_name}",
        "garbage.${var.personal_domain_name}",
        "private.${var.personal_domain_name}",
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
      "cognito-idp:CreateGroup",
      "cognito-idp:CreateIdentityProvider",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:CreateUserPoolDomain",
      "cognito-idp:DeleteGroup",
      "cognito-idp:DeleteIdentityProvider",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:DeleteUserPoolDomain",
      "cognito-idp:DescribeIdentityProvider",
      "cognito-idp:DescribeUserPool",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:GetGroup",
      "cognito-idp:GetIdentityProviderByIdentifier",
      "cognito-idp:GetLogDeliveryConfiguration",
      "cognito-idp:GetUserPoolMfaConfig",
      "cognito-idp:ListGroups",
      "cognito-idp:ListIdentityProviders",
      "cognito-idp:ListTagsForResource",
      "cognito-idp:ListUserPoolClients",
      "cognito-idp:SetLogDeliveryConfiguration",
      "cognito-idp:SetUserPoolMfaConfig",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
      "cognito-idp:UpdateGroup",
      "cognito-idp:UpdateIdentityProvider",
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
  # find the ID and then reads it. The private website creates its own. Policy
  # IDs are generated, so there's nothing narrower to scope to.
  statement {
    sid    = "CloudFrontCachePolicy"
    effect = "Allow"
    actions = [
      "cloudfront:CreateCachePolicy",
      "cloudfront:DeleteCachePolicy",
      "cloudfront:GetCachePolicy",
      "cloudfront:ListCachePolicies",
      "cloudfront:UpdateCachePolicy",
    ]
    resources = ["arn:aws:cloudfront::${var.owner_account_id}:cache-policy/*"]
  }

  statement {
    sid    = "CloudFrontOriginAccessControl"
    effect = "Allow"
    actions = [
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
    ]
    resources = ["arn:aws:cloudfront::${var.owner_account_id}:origin-access-control/*"]
  }

  # private_website_auth_boundary.tf. Anything that sets the role's
  # permissions only works with the boundary attached, and there's no
  # iam:DeleteRolePermissionsBoundary, so the role can never do more than it
  # allows.
  statement {
    sid    = "PrivateWebsiteAuthRoleBounded"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
    ]
    resources = [local.private_website_auth_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.private_website_auth_boundary_arn]
    }
  }

  # Separate from the above because iam:PolicyARN is only present on
  # attach/detach requests.
  statement {
    sid       = "PrivateWebsiteAuthRoleAttach"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy"]
    resources = [local.private_website_auth_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.private_website_auth_boundary_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
    }
  }

  statement {
    sid    = "PrivateWebsiteAuthRole"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = [local.private_website_auth_role_arn]
  }

  statement {
    sid       = "PrivateWebsiteAuthRolePass"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.private_website_auth_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # Get*/List* for the same reason as LambdaFunction in
  # kbank_email_notifications_role.tf. Lambda@Edge functions must live in
  # us-east-1; the :* ARN covers the published versions CloudFront references.
  statement {
    sid    = "PrivateWebsiteAuthFunction"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:Get*",
      "lambda:List*",
      "lambda:PublishVersion",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
    ]
    resources = [
      local.private_website_auth_function_arn,
      "${local.private_website_auth_function_arn}:*",
    ]
  }

  # CloudFront replicates the function to edge locations with the caller's
  # credentials when a distribution associates (or drops) a version.
  statement {
    sid       = "PrivateWebsiteAuthReplication"
    effect    = "Allow"
    actions   = ["lambda:EnableReplication*", "lambda:DisableReplication*"]
    resources = ["${local.private_website_auth_function_arn}:*"]
  }

  # The first Lambda@Edge association creates these service-linked roles. A
  # no-op once they exist.
  statement {
    sid       = "LambdaEdgeServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${var.owner_account_id}:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["replicator.lambda.amazonaws.com", "logger.cloudfront.amazonaws.com"]
    }
  }

  # In case the stack looks the boundary up rather than hardcoding its ARN.
  statement {
    sid       = "PrivateWebsiteAuthBoundaryRead"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = [local.private_website_auth_boundary_arn]
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
    sid     = "Buckets"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::lmacguire-ses-incoming",
      "arn:aws:s3:::${var.personal_domain_name}",
      "arn:aws:s3:::${local.private_website_bucket_name}",
    ]
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

  # The dagster stack's IAM user, its access key and inline policy
  # (dagster_boundary.tf). Scoped to that one user, and creating or changing
  # its boundary only works with the boundary attached. No AttachUserPolicy:
  # attaching managed policies would let the pipeline hand the user anything,
  # including AdministratorAccess.
  statement {
    sid    = "DagsterUserBounded"
    effect = "Allow"
    actions = [
      "iam:CreateUser",
      "iam:PutUserPermissionsBoundary",
      "iam:PutUserPolicy",
    ]
    resources = [local.dagster_user_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.dagster_boundary_arn]
    }
  }

  statement {
    sid    = "DagsterUser"
    effect = "Allow"
    actions = [
      "iam:CreateAccessKey",
      "iam:DeleteAccessKey",
      "iam:DeleteUser",
      "iam:DeleteUserPolicy",
      "iam:GetUser",
      "iam:GetUserPolicy",
      "iam:ListAccessKeys",
      "iam:ListAttachedUserPolicies",
      "iam:ListGroupsForUser",
      "iam:ListUserPolicies",
      "iam:ListUserTags",
      "iam:TagUser",
      "iam:UntagUser",
      "iam:UpdateAccessKey",
      "iam:UpdateUser",
    ]
    resources = [local.dagster_user_arn]
  }

  # In case the stack looks the boundary up rather than hardcoding its ARN.
  statement {
    sid       = "DagsterBoundaryRead"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = [local.dagster_boundary_arn]
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
