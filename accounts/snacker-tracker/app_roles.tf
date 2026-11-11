# Per-application GitHub Actions deploy roles, passed to the baseline's
# github_roles (main.tf). Each one is scoped to a single app's repo and the
# subjects it actually authenticates as (a branch ref, a GitHub Environment,
# or both), gets only the permissions that app needs to deploy, and always
# carries the app-role boundary (boundaries.tf). All predate this stack (they
# were snacker-tracker/aws-infra's), so names are unchanged.
#
# Whether a repo's sub embeds numeric org/repo IDs turned out to be per-repo,
# not org-wide: aws-infra's and interface's tokens have them,
# reporter-serverless's don't. Verify it from a live token rather than
# copying whatever the last app used.

locals {
  # Until this stack manages them (ECR, then the state bucket).
  state_bucket_arn                = "arn:aws:s3:::snacker-tracker-aws-infra-tfstate"
  interface_lambda_repository_arn = "arn:aws:ecr:${local.app_region}:${local.account_id}:repository/snacker-tracker-lambda/interface"

  app_github_roles = merge(
    {
      actions-reporter-serverless-deploy = {
        # Plain sub form, verified via a live token capture.
        repo = "snacker-tracker/reporter-serverless"
        # test/build run on a plain branch push; deploy-dev and deploy-prod
        # are gated by GitHub Environments, which replaces the token's
        # subject entirely (environment:NAME instead of ref:...).
        subjects             = ["ref:refs/heads/master", "environment:dev", "environment:prod"]
        permissions_boundary = "app-role-permissions-boundary"
        inline_policies = {
          github-actions-reporter-serverless-deploy-permissions = data.aws_iam_policy_document.reporter_serverless_deploy.json
        }
      }
    },
    {
      for env, config in local.interface : "actions-interface-${env}" => {
        repo                 = "snacker-tracker@59108816/interface@1428184726"
        subjects             = config.subjects
        permissions_boundary = "app-role-permissions-boundary"
        managed_policies     = [for key in keys(local.interface_policies[env]) : "github-actions-interface-${env}-${key}"]
      }
    },
  )

  # Managed rather than inline: a role's inline policies share one 10,240
  # character limit, while each managed policy gets 6,144 of its own, and
  # interface's permissions are too large for one.
  interface_policies = {
    for env in keys(local.interface) : env => {
      workloads = data.aws_iam_policy_document.interface_workloads[env].json
      edge      = data.aws_iam_policy_document.interface_edge[env].json
      logs      = data.aws_iam_policy_document.interface_access_logs[env].json
      guards    = data.aws_iam_policy_document.interface_guards[env].json
    }
  }

  app_managed_policies = merge([
    for env, policies in local.interface_policies : {
      for key, policy in policies : "github-actions-interface-${env}-${key}" => { policy = policy }
    }
  ]...)
}

# --- reporter-serverless ---
#
# Deploy role for github.com/snacker-tracker/reporter-serverless's CI
# pipeline, replacing the static AWS access keys it used to authenticate
# with.
#
# Scoped pragmatically by resource-name prefix per service, matching that
# app's own Terraform naming convention (`${var.api_name}-*-${workspace}`,
# api_name defaulting to "snacker-tracker", workspace being "dev" or
# "prod"). Not scoped to exact ARNs where API Gateway/ACM/Lambda
# event-source-mappings don't support pre-creation resource ARNs at all.

locals {
  reporter_serverless_runtime_roles = [
    "arn:aws:iam::*:role/snacker-tracker-lambda-execution-*",
    "arn:aws:iam::*:role/snacker-tracker-api-gateway-firehose-role-*",
    "arn:aws:iam::*:role/snacker-tracker-eb-delivery-*",
    "arn:aws:iam::*:role/firehose-delivery-*",
  ]
}

data "aws_iam_policy_document" "reporter_serverless_deploy" {
  statement {
    sid    = "LambdaFunctions"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:DeleteFunction",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
      "lambda:PublishVersion",
      "lambda:ListVersionsByFunction",
      "lambda:CreateAlias",
      "lambda:UpdateAlias",
      "lambda:DeleteAlias",
      "lambda:GetAlias",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
    ]
    resources = ["arn:aws:lambda:*:*:function:snacker-tracker-*"]
  }

  statement {
    sid    = "LambdaEventSourceMappings"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
    ]
    # Event source mapping ARNs are UUID-based and unknown pre-creation;
    # IAM doesn't support scoping these to the underlying function/queue.
    resources = ["*"]
  }

  # The app's own runtime roles, by the names its Terraform gives them:
  # "${api_name}-<role>-${workspace}" (api_name defaulting to
  # "snacker-tracker"), or a name_prefix for the Firehose and EventBridge
  # ones. Exact prefixes rather than snacker-tracker-*, which would also
  # cover interface's roles (snacker-tracker-<env>-*).
  statement {
    sid    = "OwnServiceRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PassRole",
    ]
    resources = local.reporter_serverless_runtime_roles
  }

  # Creating a role, or changing what it may do, only when it carries
  # reporter-serverless-runtime-boundary (boundaries.tf): whatever policy
  # the app writes, its roles reach only its own resources and can never
  # manage IAM. No AttachRolePolicy: the app only uses inline policies, and
  # attaching would allow AWS managed ones such as AdministratorAccess.
  # Detach stays for deleting roles. No DeleteRolePermissionsBoundary, so
  # the boundary can't be taken off.
  statement {
    sid    = "OwnServiceRolePermissions"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = local.reporter_serverless_runtime_roles
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [module.baseline.managed_policy_arns["reporter-serverless-runtime-boundary"]]
    }
  }

  statement {
    sid    = "OwnStandalonePolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
    ]
    resources = ["arn:aws:iam::*:policy/firehose-*"]
  }

  statement {
    sid       = "ApiGateway"
    effect    = "Allow"
    actions   = ["apigateway:*"]
    resources = ["arn:aws:apigateway:*::/*"]
  }

  # Edge-optimized API Gateway custom domains provision a CloudFront
  # distribution internally, but API Gateway still checks that the
  # *caller* holds cloudfront:UpdateDistribution before associating a
  # cert with it, as CreateDomainName's own error message says. Resource
  # "*" because the distribution ID is managed internally by API Gateway,
  # never exposed for scoping.
  statement {
    sid       = "CloudFrontForApiGatewayCustomDomain"
    effect    = "Allow"
    actions   = ["cloudfront:UpdateDistribution"]
    resources = ["*"]
  }

  statement {
    sid    = "AcmForCustomDomain"
    effect = "Allow"
    actions = [
      "acm:RequestCertificate",
      "acm:DescribeCertificate",
      "acm:DeleteCertificate",
      "acm:ListCertificates",
      "acm:AddTagsToCertificate",
      "acm:ListTagsForCertificate",
    ]
    # No pre-creation ARN to scope to (random cert ID at issue time). Runs
    # via that repo's aws.us-east-1 provider alias: edge-optimized API
    # Gateway custom domains require the cert in us-east-1 specifically.
    resources = ["*"]
  }

  statement {
    sid    = "Route53ForKhanomXyz"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:GetHostedZone",
    ]
    resources = [aws_route53_zone.khanom_xyz.arn]
  }

  statement {
    sid       = "Route53GetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid    = "EventBridge"
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:DescribeRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:DeleteRule",
      "events:ListTargetsByRule",
      "events:TagResource",
      "events:UntagResource",
      "events:ListTagsForResource",
      "events:CreateEventBus",
      "events:DeleteEventBus",
      "events:DescribeEventBus",
    ]
    resources = [
      "arn:aws:events:*:*:rule/snacker-tracker-*",
      "arn:aws:events:*:*:event-bus/snacker-tracker-*",
    ]
  }

  statement {
    sid    = "Firehose"
    effect = "Allow"
    actions = [
      "firehose:CreateDeliveryStream",
      "firehose:DeleteDeliveryStream",
      "firehose:DescribeDeliveryStream",
      "firehose:UpdateDestination",
      "firehose:TagDeliveryStream",
      "firehose:ListTagsForDeliveryStream",
    ]
    resources = ["arn:aws:firehose:*:*:deliverystream/snacker-tracker-*"]
  }

  statement {
    sid    = "Sqs"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:GetQueueAttributes",
      "sqs:SetQueueAttributes",
      "sqs:TagQueue",
      "sqs:UntagQueue",
      "sqs:GetQueueUrl",
      "sqs:ListQueueTags",
    ]
    resources = ["arn:aws:sqs:*:*:snacker-tracker-*"]
  }

  statement {
    sid    = "S3FirehoseDestinationBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:GetBucketPolicy",
      "s3:PutBucketAcl",
      "s3:GetBucketAcl",
      "s3:PutEncryptionConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:PutBucketTagging",
      "s3:GetBucketTagging",
      "s3:PutBucketVersioning",
      "s3:GetBucketVersioning",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPublicAccessBlock",
      # The rest of these are never explicitly set by this app's .tf, but
      # aws_s3_bucket's read/refresh cycle checks every sub-configuration
      # a bucket can have regardless (CORS, website, logging, etc.):
      # missing any one of these fails plan/apply on this resource.
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:GetReplicationConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketNotification",
      # Not just a read-cycle check: aws_s3_bucket_notification wires this
      # bucket's events to the app's s3-to-lambda SQS queue.
      "s3:PutBucketNotification",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    # Exact bucket names, not a snacker-tracker-* wildcard: that prefix is
    # shared with the snacker-tracker-aws-infra-tfstate state bucket, and a
    # wildcard would grant this role write/delete access to it.
    resources = [
      "arn:aws:s3:::snacker-tracker-dev",
      "arn:aws:s3:::snacker-tracker-dev/*",
      "arn:aws:s3:::snacker-tracker-prod",
      "arn:aws:s3:::snacker-tracker-prod/*",
    ]
  }

  # Lets reporter-serverless store its own Terraform state in the
  # snacker-tracker-aws-infra-tfstate bucket, at the bare key
  # "snacker-tracker-reporter-serverless" (that repo's backend key has no
  # "/terraform.tfstate" suffix: it IS the object name). Both the bare-key
  # and "/*" forms are listed: a "prefix/*" ARN pattern requires a literal
  # "/" after the prefix, so it does NOT match an object whose key is
  # exactly the prefix (this caused 403s before the bare-key entries were
  # added). The "/*" forms remain in case that key ever gains a filename
  # suffix. Two prefix variants (plain and "env:/<workspace>/...") because
  # that repo uses Terraform workspaces (dev/prod), which nest state under a
  # literal "env:/<workspace>/" prefix BEFORE the key.
  statement {
    sid    = "SharedStateBucketForReporterServerless"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${local.state_bucket_arn}/snacker-tracker-reporter-serverless",
      "${local.state_bucket_arn}/snacker-tracker-reporter-serverless/*",
      "${local.state_bucket_arn}/env:/*/snacker-tracker-reporter-serverless",
      "${local.state_bucket_arn}/env:/*/snacker-tracker-reporter-serverless/*",
    ]
  }

  statement {
    sid       = "SharedStateBucketListForReporterServerless"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["snacker-tracker-reporter-serverless/*", "env:/*/snacker-tracker-reporter-serverless/*"]
    }
  }

  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = ["arn:aws:ecr:*:*:repository/snacker-tracker-lambda*"]
  }

  statement {
    sid    = "CloudWatchLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/apigateway/*",
      "arn:aws:logs:*:*:log-group:/aws/lambda/snacker-tracker-*",
      "arn:aws:logs:*:*:log-group:API-Gateway-Execution-Logs*",
    ]
  }

  # DescribeLogGroups is a list operation: AWS doesn't support scoping it
  # to specific log-group ARNs, it always needs Resource "*" (the
  # AccessDenied error names a placeholder ARN, not a real one).
  statement {
    sid       = "CloudWatchLogGroupsDescribe"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "StsIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

import {
  to = module.baseline.aws_iam_role.github["actions-reporter-serverless-deploy"]
  id = "github-actions-reporter-serverless-deploy"
}

import {
  to = module.baseline.aws_iam_role_policy.github["actions-reporter-serverless-deploy/github-actions-reporter-serverless-deploy-permissions"]
  id = "github-actions-reporter-serverless-deploy:github-actions-reporter-serverless-deploy-permissions"
}

# --- interface ---
#
# Deploy roles for github.com/snacker-tracker/interface, one per environment
# (github-actions-interface-dev, github-actions-interface-prod). They apply
# that repo's infra/main configuration and publish its frontend.
#
# Ported from interface's infra/admin/ci_role.tf (its ADR 0005), which
# created them as snacker-tracker-<env>-ci. The policies are written against
# the names interface's admin configuration and main configuration use, so
# a new permission for interface's CI is now a change here:
# - functions, schedules and log groups snacker-tracker-<env>-*
# - the buckets snacker-tracker-<env>-{site,working,access-logs}
# - the state machines snacker-tracker-<env>-* (the stepdag graph, interface #121)
# - the workload roles snacker-tracker-<env>-{build,extraction,scheduler},
#   snacker-tracker-<env>-graph-* and snacker-tracker-<env>-graph-state-machine,
#   which interface's admin configuration still creates
# - CloudFront distributions and ACM certificates tagged
#   Project=snacker-tracker
# - the state key env:/<env>/snacker-tracker-interface in the
#   snacker-tracker-aws-infra-tfstate bucket
#
# The CI role manages only those resources. On IAM it can only read and pass
# its environment's workload roles; it never writes a permission.

locals {
  interface_environments = {
    dev = {
      raw_bucket      = "snacker-tracker-dev"
      hostnames       = ["dev.khanom.xyz"]
      can_push_images = true
      # Pull requests plan in dev only, so they can never assume the prod role.
      subjects = ["environment:dev", "pull_request"]
    }
    prod = {
      raw_bucket      = "snacker-tracker-prod"
      hostnames       = ["khanom.xyz", "www.khanom.xyz"]
      can_push_images = false
      subjects        = ["environment:prod"]
    }
  }

  interface_function_arn     = "arn:aws:lambda:${local.app_region}:${local.account_id}:function"
  interface_log_group_arn    = "arn:aws:logs:${local.app_region}:${local.account_id}:log-group:/aws/lambda"
  interface_role_arn         = "arn:aws:iam::${local.account_id}:role"
  interface_log_delivery_arn = "arn:aws:logs:us-east-1:${local.account_id}"
  interface_raw_buckets      = [for env in values(local.interface_environments) : env.raw_bucket]
  interface_project_tag      = { variable = "Project", value = "snacker-tracker" }

  interface = {
    for env, config in local.interface_environments : env => merge(config, {
      prefix                 = "snacker-tracker-${env}"
      site_bucket_arn        = "arn:aws:s3:::snacker-tracker-${env}-site"
      working_bucket         = "snacker-tracker-${env}-working"
      access_logs_bucket_arn = "arn:aws:s3:::snacker-tracker-${env}-access-logs"
      access_log_group_arn   = "${local.interface_log_delivery_arn}:log-group:/aws/vendedlogs/cloudfront/snacker-tracker-${env}-*"
      main_state_object      = "env:/${env}/snacker-tracker-interface"
      workload_roles = {
        # The graph's functions run as one role per manifest role, snacker-tracker-<env>-graph-<role>.
        lambda = [
          "${local.interface_role_arn}/snacker-tracker-${env}-build",
          "${local.interface_role_arn}/snacker-tracker-${env}-extraction",
          "${local.interface_role_arn}/snacker-tracker-${env}-graph-*",
        ]
        scheduler = ["${local.interface_role_arn}/snacker-tracker-${env}-scheduler"]
        states    = ["${local.interface_role_arn}/snacker-tracker-${env}-graph-state-machine"]
      }
    })
  }
}

# Functions, schedule, logs, the working bucket, the site's frontend files, the image.
data "aws_iam_policy_document" "interface_workloads" {
  for_each = local.interface

  # No AddPermission or function URLs: those are resource policies, and nothing needs them.
  statement {
    sid = "Functions"
    actions = [
      "lambda:Get*", "lambda:List*",
      "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:PublishVersion",
      "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
      "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency",
      "lambda:PutFunctionEventInvokeConfig", "lambda:UpdateFunctionEventInvokeConfig",
      "lambda:DeleteFunctionEventInvokeConfig",
      "lambda:TagResource", "lambda:UntagResource", "lambda:InvokeFunction",
    ]
    resources = ["${local.interface_function_arn}:${each.value.prefix}-*"]
  }

  # ValidateStateMachineDefinition checks a definition without naming a state machine, so IAM
  # sees it on stateMachine:*; it reads nothing.
  statement {
    sid       = "ListFunctions"
    actions   = ["lambda:ListFunctions", "scheduler:ListSchedules", "logs:DescribeLogGroups", "states:ListStateMachines", "states:ValidateStateMachineDefinition"]
    resources = ["*"]
  }

  # The stepdag graph's state machine (interface #121). Its executions are started by the schedules,
  # whose role the admin configuration grants; CI never starts or stops one.
  statement {
    sid = "StateMachines"
    actions = [
      "states:CreateStateMachine", "states:UpdateStateMachine", "states:DeleteStateMachine",
      "states:DescribeStateMachine", "states:ListStateMachineVersions",
      "states:TagResource", "states:UntagResource", "states:ListTagsForResource",
    ]
    resources = ["arn:aws:states:${local.app_region}:${local.account_id}:stateMachine:${each.value.prefix}-*"]
  }

  statement {
    sid = "Schedule"
    actions = [
      "scheduler:GetSchedule", "scheduler:CreateSchedule",
      "scheduler:UpdateSchedule", "scheduler:DeleteSchedule",
    ]
    resources = ["arn:aws:scheduler:${local.app_region}:${local.account_id}:schedule/default/${each.value.prefix}-*"]
  }

  statement {
    sid = "LogGroups"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource",
      "logs:ListTagsForResource", "logs:TagLogGroup", "logs:ListTagsLogGroup",
    ]
    resources = ["${local.interface_log_group_arn}/${each.value.prefix}-*", each.value.access_log_group_arn]
  }

  # Bucket and object policies, ACLs and public access are denied in interface_guards.
  statement {
    sid       = "WorkingBucket"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${each.value.working_bucket}", "arn:aws:s3:::${each.value.working_bucket}/*"]
  }

  statement {
    sid       = "ReadSiteBucket"
    actions   = ["s3:ListBucket", "s3:GetBucket*", "s3:GetEncryptionConfiguration"]
    resources = [each.value.site_bucket_arn]
  }

  # data/* is the build's alone (interface's ADR 0004); the deny is in interface_guards.
  statement {
    sid       = "FrontendFiles"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${each.value.site_bucket_arn}/*"]
  }

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Dev builds the image; prod only reads it (interface's ADR 0006), except that each
  # environment tags the image it deploys, so the ECR lifecycle rules keep it. PutImage
  # without the layer uploads can only add a manifest whose layers are already there.
  statement {
    sid = "Image"
    actions = concat(
      [
        "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability",
        "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:PutImage",
      ],
      each.value.can_push_images ? [
        "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
      ] : [],
    )
    resources = [local.interface_lambda_repository_arn]
  }
}

# CloudFront, its certificate and DNS records.
data "aws_iam_policy_document" "interface_edge" {
  for_each = local.interface

  # Creates take no resource ARN (the ID doesn't exist yet), only "*"; the tag scopes them.
  statement {
    sid       = "CreateTaggedDistributions"
    actions   = ["cloudfront:CreateDistribution", "cloudfront:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.interface_project_tag.variable}"
      values   = [local.interface_project_tag.value]
    }
  }

  statement {
    sid = "ManageTaggedDistributions"
    actions = [
      "cloudfront:GetDistribution", "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
      "cloudfront:ListTagsForResource", "cloudfront:UntagResource",
      "cloudfront:CreateInvalidation", "cloudfront:GetInvalidation",
    ]
    resources = ["arn:aws:cloudfront::${local.account_id}:distribution/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.interface_project_tag.variable}"
      values   = [local.interface_project_tag.value]
    }
  }

  # Origin access controls can't carry tags. They grant nothing by themselves: the site
  # bucket's policy decides what CloudFront may read.
  statement {
    sid       = "CreateOriginAccessControls"
    actions   = ["cloudfront:CreateOriginAccessControl"]
    resources = ["*"]
  }

  statement {
    sid = "OriginAccessControls"
    actions = [
      "cloudfront:GetOriginAccessControl", "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
    ]
    resources = ["arn:aws:cloudfront::${local.account_id}:origin-access-control/*"]
  }

  statement {
    sid = "ReadCloudFront"
    actions = [
      "cloudfront:ListDistributions", "cloudfront:ListOriginAccessControls",
      "cloudfront:GetCachePolicy", "cloudfront:ListCachePolicies",
      "cloudfront:GetOriginRequestPolicy", "cloudfront:ListOriginRequestPolicies",
      "cloudfront:GetResponseHeadersPolicy", "cloudfront:ListResponseHeadersPolicies",
      "acm:ListCertificates",
    ]
    resources = ["*"]
  }

  # CloudFront certificates live in us-east-1. Requests take no resource ARN, only "*".
  statement {
    sid       = "RequestTaggedCertificates"
    actions   = ["acm:RequestCertificate", "acm:AddTagsToCertificate"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.interface_project_tag.variable}"
      values   = [local.interface_project_tag.value]
    }
  }

  statement {
    sid = "ManageTaggedCertificates"
    actions = [
      "acm:DescribeCertificate", "acm:GetCertificate", "acm:DeleteCertificate",
      "acm:ListTagsForCertificate", "acm:RemoveTagsFromCertificate",
    ]
    resources = ["arn:aws:acm:us-east-1:${local.account_id}:certificate/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.interface_project_tag.variable}"
      values   = [local.interface_project_tag.value]
    }
  }

  statement {
    sid       = "ReadZone"
    actions   = ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = [aws_route53_zone.khanom_xyz.arn]
  }

  statement {
    sid       = "FindZoneAndChanges"
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:GetChange"]
    resources = ["*"]
  }

  # Only this environment's names and their ACM validation records (_<token>.<name>).
  statement {
    sid       = "OwnRecords"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.khanom_xyz.arn]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = flatten([for name in each.value.hostnames : [name, "_*.${name}"]])
    }
  }
}

# CloudFront access log delivery (interface's ADR 0010).
data "aws_iam_policy_document" "interface_access_logs" {
  for_each = local.interface

  # Lets this account's log delivery read the distribution's logs. It grants no principal access to
  # anything: where the logs may land is still decided by interface's access-log bucket and
  # CloudWatch Logs resource policies.
  statement {
    sid       = "VendDistributionLogs"
    actions   = ["cloudfront:AllowVendedLogDeliveryForResource"]
    resources = ["arn:aws:cloudfront::${local.account_id}:distribution/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.interface_project_tag.variable}"
      values   = [local.interface_project_tag.value]
    }
  }

  # No delivery destination policies: those are only for cross-account delivery, and are permissions.
  # Delivery IDs are generated, so deliveries can't be scoped by name.
  statement {
    sid = "Deliveries"
    actions = [
      "logs:PutDeliverySource", "logs:GetDeliverySource", "logs:DeleteDeliverySource",
      "logs:PutDeliveryDestination", "logs:GetDeliveryDestination", "logs:DeleteDeliveryDestination",
      "logs:CreateDelivery", "logs:GetDelivery", "logs:DeleteDelivery", "logs:UpdateDeliveryConfiguration",
      "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
    ]
    resources = [
      "${local.interface_log_delivery_arn}:delivery-source:${each.value.prefix}-*",
      "${local.interface_log_delivery_arn}:delivery-destination:${each.value.prefix}-*",
      "${local.interface_log_delivery_arn}:delivery:*",
    ]
  }

  # Delivery reads the destinations' policies to check it may write; it never changes them here.
  statement {
    sid = "ReadDeliveries"
    actions = [
      "logs:DescribeDeliverySources", "logs:DescribeDeliveryDestinations", "logs:DescribeDeliveries",
      "logs:DescribeConfigurationTemplates", "logs:DescribeResourcePolicies",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAccessLogsBucketPolicy"
    actions   = ["s3:GetBucketPolicy"]
    resources = [each.value.access_logs_bucket_arn]
  }
}

# Terraform state, IAM, and the denies that hold whatever the allows above say.
data "aws_iam_policy_document" "interface_guards" {
  for_each = local.interface

  # The S3 backend lists env:/ to find workspaces, which shows other configurations' key
  # names but none of their contents.
  statement {
    sid       = "ListOwnState"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["env:/", "${each.value.main_state_object}*"]
    }
  }

  statement {
    sid       = "OwnState"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.state_bucket_arn}/${each.value.main_state_object}"]
  }

  statement {
    sid       = "OwnStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_bucket_arn}/${each.value.main_state_object}.tflock"]
  }

  statement {
    sid       = "ReadWorkloadRoles"
    actions   = ["iam:GetRole"]
    resources = flatten(values(each.value.workload_roles))
  }

  dynamic "statement" {
    for_each = each.value.workload_roles
    content {
      sid       = "PassTo${title(statement.key)}"
      actions   = ["iam:PassRole"]
      resources = statement.value
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["${statement.key}.amazonaws.com"]
      }
    }
  }

  statement {
    sid       = "NotData"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${each.value.site_bucket_arn}/data/*"]
  }

  statement {
    sid       = "NotRawEvents"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = flatten([for bucket in local.interface_raw_buckets : ["arn:aws:s3:::${bucket}", "arn:aws:s3:::${bucket}/*"]])
  }

  statement {
    sid    = "NoBucketPermissions"
    effect = "Deny"
    actions = [
      "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketAcl", "s3:PutObjectAcl",
      "s3:PutBucketPublicAccessBlock", "s3:PutAccountPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
    ]
    resources = ["*"]
  }

  # The project tag is what scopes CloudFront and ACM; removing it would hide a resource.
  statement {
    sid       = "KeepProjectTag"
    effect    = "Deny"
    actions   = ["cloudfront:UntagResource", "acm:RemoveTagsFromCertificate"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:TagKeys"
      values   = [local.interface_project_tag.variable]
    }
  }
}

import {
  for_each = local.interface
  to       = module.baseline.aws_iam_role.github["actions-interface-${each.key}"]
  id       = "github-actions-interface-${each.key}"
}

import {
  for_each = toset(flatten([for env, policies in local.interface_policies : [for key in keys(policies) : "github-actions-interface-${env}-${key}"]]))
  to       = module.baseline.aws_iam_policy.managed[each.key]
  id       = "arn:aws:iam::${local.account_id}:policy/${each.key}"
}

import {
  for_each = {
    for pair in flatten([
      for env, policies in local.interface_policies : [
        for key in keys(policies) : { role = "github-actions-interface-${env}", policy = "github-actions-interface-${env}-${key}", key = "actions-interface-${env}" }
      ]
    ]) : pair.policy => pair
  }
  to = module.baseline.aws_iam_role_policy_attachment.github["${each.value.key}/managed/${each.key}"]
  id = "${each.value.role}/arn:aws:iam::${local.account_id}:policy/${each.key}"
}
