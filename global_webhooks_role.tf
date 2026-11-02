# GitHub Actions deploy role for leprechaun/terraform-global-webhooks. Its
# pipeline runs `terraform apply` on that repo, so these permissions mirror the
# API Gateway + EventBridge + Firehose + S3 stack it manages there.

locals {
  global_webhooks_github_actions_role_name = "terraform-global-webhooks-github-actions"
  global_webhooks_region                   = "ap-southeast-1"
  global_webhooks_zone_id                  = "Z1Y1LAL56TU5W6"
  global_webhooks_service_role_arns = [
    "arn:aws:iam::${var.owner_account_id}:role/api-gateway-firehose-role",
    "arn:aws:iam::${var.owner_account_id}:role/eventbridge-delivery-role",
    "arn:aws:iam::${var.owner_account_id}:role/firehose-delivery*",
  ]
}

data "aws_iam_policy_document" "global_webhooks_github_actions_assume_role" {
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

    # Only runs on master. That pipeline has a single deploy with no
    # `environment:` set, so its claim is ref-scoped. Both sub claim forms are
    # listed because this repo's use_immutable_subject setting hasn't been
    # confirmed; drop whichever one
    # GET /repos/OWNER/REPO/actions/oidc/customization/sub says doesn't apply,
    # and pin the repo ID if it's the immutable form.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun/terraform-global-webhooks:ref:refs/heads/master",
        "repo:leprechaun@355637/terraform-global-webhooks@*:ref:refs/heads/master",
      ]
    }
  }
}

resource "aws_iam_role" "global_webhooks_github_actions" {
  name               = local.global_webhooks_github_actions_role_name
  assume_role_policy = data.aws_iam_policy_document.global_webhooks_github_actions_assume_role.json

  tags = {
    Project   = "global-webhooks"
    Component = "deploy"
  }

  # Same ordering as the kbank role: apply needs its
  # ManageGlobalWebhooksGithubActionsRole statement before it can create this.
  depends_on = [aws_iam_role_policy.github_actions]
}

data "aws_iam_policy_document" "global_webhooks_github_actions_deploy" {
  # The backend's key isn't known from here, so this matches on the project
  # name instead of an exact key. Also covers the .tflock variant.
  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/*webhooks*"]
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
      values   = ["*webhooks*", "env:/*"]
    }
  }

  # REST API IDs are generated at create time, so this can't be narrowed to
  # one API. Covers every REST API and custom domain in this region.
  statement {
    sid     = "ApiGateway"
    effect  = "Allow"
    actions = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
    resources = [
      "arn:aws:apigateway:${local.global_webhooks_region}::/restapis",
      "arn:aws:apigateway:${local.global_webhooks_region}::/restapis/*",
      "arn:aws:apigateway:${local.global_webhooks_region}::/domainnames",
      "arn:aws:apigateway:${local.global_webhooks_region}::/domainnames/*",
      "arn:aws:apigateway:${local.global_webhooks_region}::/tags/*",
    ]
  }

  # Edge-optimized custom domains are backed by a CloudFront distribution that
  # API Gateway owns, and it acts on it using the caller's permissions. There's
  # no ARN to scope to.
  statement {
    sid       = "ApiGatewayEdgeDomainCloudFront"
    effect    = "Allow"
    actions   = ["cloudfront:UpdateDistribution"]
    resources = ["*"]
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
      values   = ["us-east-1"]
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
    resources = ["arn:aws:acm:us-east-1:${var.owner_account_id}:certificate/*"]
  }

  statement {
    sid    = "Route53ZoneRead"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["arn:aws:route53:::hostedzone/${local.global_webhooks_zone_id}"]
  }

  # ListHostedZones doesn't support resource-level scoping.
  statement {
    sid       = "Route53ZoneList"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }

  # Only the API's own alias and its ACM validation record. Matches on the
  # leading label so the domain itself stays out of this repo: see
  # personal_domain_name in variables.tf.
  statement {
    sid       = "Route53RecordWrite"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${local.global_webhooks_zone_id}"]

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["webhooks.*", "_*.webhooks.*"]
    }
  }

  statement {
    sid       = "Route53Change"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid    = "ApiGatewayLogGroup"
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
      "arn:aws:logs:${local.global_webhooks_region}:${var.owner_account_id}:log-group:/aws/apigateway/webhooks-*",
      "arn:aws:logs:${local.global_webhooks_region}:${var.owner_account_id}:log-group:/aws/apigateway/webhooks-*:*",
    ]
  }

  statement {
    sid       = "LogGroupDescribe"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${local.global_webhooks_region}:${var.owner_account_id}:log-group:*"]
  }

  # Bus, rule and target management only: no events:PutEvents.
  statement {
    sid    = "EventBridge"
    effect = "Allow"
    actions = [
      "events:CreateEventBus",
      "events:DeleteEventBus",
      "events:DeleteRule",
      "events:DescribeEventBus",
      "events:DescribeRule",
      "events:ListTagsForResource",
      "events:ListTargetsByRule",
      "events:PutRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:TagResource",
      "events:UntagResource",
    ]
    resources = [
      "arn:aws:events:${local.global_webhooks_region}:${var.owner_account_id}:event-bus/everything",
      "arn:aws:events:${local.global_webhooks_region}:${var.owner_account_id}:rule/everything/*",
    ]
  }

  # Stream management only: no firehose:PutRecord.
  statement {
    sid    = "Firehose"
    effect = "Allow"
    actions = [
      "firehose:CreateDeliveryStream",
      "firehose:DeleteDeliveryStream",
      "firehose:DescribeDeliveryStream",
      "firehose:ListTagsForDeliveryStream",
      "firehose:TagDeliveryStream",
      "firehose:UntagDeliveryStream",
      "firehose:UpdateDestination",
    ]
    resources = ["arn:aws:firehose:${local.global_webhooks_region}:${var.owner_account_id}:deliverystream/webhooks*"]
  }

  # s3:* for the same reason as CloudTrailAndCostExportBuckets in
  # github_oidc.tf, but on the bucket ARN only, which excludes object actions.
  statement {
    sid       = "FirehoseDestinationBucket"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::lmacguire-firehose"]
  }

  # force_destroy on that bucket empties it first. No s3:GetObject, so the
  # pipeline can't read the webhook payloads stored there.
  statement {
    sid       = "FirehoseDestinationBucketEmpty"
    effect    = "Allow"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["arn:aws:s3:::lmacguire-firehose/*"]
  }

  statement {
    sid    = "ServiceRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = local.global_webhooks_service_role_arns
  }

  statement {
    sid       = "ServiceRolesPass"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.global_webhooks_service_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["apigateway.amazonaws.com", "events.amazonaws.com", "firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "global_webhooks_github_actions_deploy" {
  name   = "deploy"
  role   = aws_iam_role.global_webhooks_github_actions.id
  policy = data.aws_iam_policy_document.global_webhooks_github_actions_deploy.json
}
