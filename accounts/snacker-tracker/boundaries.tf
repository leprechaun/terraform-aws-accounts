# Permissions boundaries, created through the baseline's managed_policies
# (main.tf) so github_roles can name them as permissions_boundary. All three
# predate this stack (they were snacker-tracker/aws-infra's).

locals {
  # The apps run in ap-southeast-1; IAM itself is global, which is why this
  # stack's provider region doesn't matter here.
  app_region = "ap-southeast-1"
}

# Permissions boundary attached to every per-app GitHub Actions role. It
# doesn't restrict which AWS services an app can use (that's controlled by
# each role's own policy); it hard-blocks mutation of the CI/deploy-role
# layer itself and account-wide IAM settings, so no app role can grant
# itself (or another app's deploy role) more access, touch this boundary,
# or touch the OIDC provider, no matter what its own policy says.
#
# This does NOT block apps from creating/managing their OWN runtime IAM
# roles (e.g. a Lambda execution role, a Firehose delivery role): several
# apps' own Terraform manages IAM resources for services to assume, and a
# blanket IAM deny would break that. Residual risk: since this only
# protects the CI-identity layer BY NAME, an app's deploy role could in
# principle still tamper with a DIFFERENT app's runtime role if it knew its
# ARN. Closing that fully would mean requiring every app's own Terraform to
# attach a runtime-role boundary to whatever it creates, which needs
# changes in each app's own repo.
data "aws_iam_policy_document" "app_role_boundary" {
  statement {
    sid       = "AllowEverythingByDefault"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  # Always denied, regardless of resource: account-wide IAM settings and
  # identity-provider/user management. Not scoped to "our" resources
  # because most of these actions aren't resource-scopable in IAM anyway.
  statement {
    sid    = "DenyAccountWideIamActions"
    effect = "Deny"
    actions = [
      "iam:CreateAccountAlias",
      "iam:DeleteAccountAlias",
      "iam:UpdateAccountPasswordPolicy",
      "iam:DeleteAccountPasswordPolicy",
      "iam:CreateSAMLProvider",
      "iam:UpdateSAMLProvider",
      "iam:DeleteSAMLProvider",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:CreateAccessKey",
      "iam:UpdateAccessKey",
      "iam:DeleteAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:DeleteLoginProfile",
      "iam:CreateVirtualMFADevice",
      "iam:DeactivateMFADevice",
      "iam:DeleteVirtualMFADevice",
    ]
    resources = ["*"]
  }

  # Denied only when targeting the CI/deploy-role layer specifically: any
  # github-actions-* role (every github_roles key here starts with
  # actions-), this boundary itself, the runtime-role boundaries below, and
  # the OIDC provider. Mutating a non-CI-named role or policy (an app's own
  # runtime role) is left to AllowEverythingByDefault, controlled instead by
  # each app role's own policy.
  statement {
    sid    = "DenyMutatingCiIdentityLayer"
    effect = "Deny"
    actions = [
      "iam:Add*",
      "iam:Attach*",
      "iam:Create*",
      "iam:Delete*",
      "iam:Detach*",
      "iam:Put*",
      "iam:Remove*",
      "iam:Set*",
      "iam:Update*",
    ]
    resources = [
      "arn:aws:iam::*:role/github-actions-*",
      "arn:aws:iam::*:policy/app-role-permissions-boundary",
      "arn:aws:iam::*:policy/runtime-role-permissions-boundary",
      "arn:aws:iam::*:policy/reporter-serverless-runtime-boundary",
      "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com",
    ]
  }
}

# Permissions boundary for the runtime roles apps create for themselves
# (Lambda execution roles, Firehose/EventBridge/API Gateway delivery roles,
# ...). The app-role boundary limits what an app's deploy role can do, but
# not what the roles it creates can do: without this, a deploy role allowed
# to create and attach policies to its own runtime roles can create one
# with AdministratorAccess and assume it.
#
# This closes that once app deploy roles may only create, or change the
# permissions of, roles carrying this boundary (an iam:PermissionsBoundary
# condition on their IAM statements). Runtime roles never need IAM, so
# denying it outright costs them nothing, and nothing a runtime role does
# can widen any role's permissions, its own included.
#
# Attaching it to a role constrains that role only; it has no effect until
# an app's Terraform sets it as permissions_boundary on its roles.
data "aws_iam_policy_document" "runtime_role_boundary" {
  statement {
    sid       = "AllowEverythingByDefault"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyIdentityAndAccountManagement"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }
}

# Permissions boundary for reporter-serverless's runtime roles: the most any
# of them may ever do, whatever policy or trust that app's deploy role gives
# them. Unlike the generic runtime boundary it allows only what those roles
# use, so a role the pipeline rewrote and assumed would still reach nothing
# but the app's own resources:
#
# - Lambda (append/rebuild/compact-bronze): its bucket, the S3-to-Lambda
#   queue (through the event source mapping), its functions' log groups
# - Firehose: writes the bucket
# - API Gateway: puts events on the bus
# - EventBridge: puts records on the stream, dead letters on the DLQ
#
# Names are listed exactly per workspace, never snacker-tracker-*: that
# would also match interface's buckets and log groups, and the
# snacker-tracker-aws-infra-tfstate bucket. Narrower scoping (raw/* vs
# bronze/*) is the roles' own policies' job.
#
# Not allowed, though the roles' policies grant it: logs:* on "*" for the
# Firehose and EventBridge roles (the stream has no logging configured, and
# EventBridge targets don't log).
locals {
  reporter_serverless_workspaces = ["dev", "prod"]

  reporter_serverless_buckets = [for ws in local.reporter_serverless_workspaces : "arn:aws:s3:::snacker-tracker-${ws}"]
  reporter_serverless_streams = [for ws in local.reporter_serverless_workspaces : "arn:aws:firehose:${local.app_region}:${local.account_id}:deliverystream/snacker-tracker-${ws}"]
  reporter_serverless_buses   = [for ws in local.reporter_serverless_workspaces : "arn:aws:events:${local.app_region}:${local.account_id}:event-bus/snacker-tracker-${ws}"]
  reporter_serverless_queues  = [for ws in local.reporter_serverless_workspaces : "arn:aws:sqs:${local.app_region}:${local.account_id}:snacker-tracker-s3-to-lambda-${ws}"]
  reporter_serverless_dlqs    = [for ws in local.reporter_serverless_workspaces : "arn:aws:sqs:${local.app_region}:${local.account_id}:snacker-tracker-eventbridge-dlq-${ws}"]
  reporter_serverless_log_groups = flatten([
    for ws in local.reporter_serverless_workspaces : [
      for function in ["append-to-bronze", "rebuild-bronze", "compact-bronze"] :
      "arn:aws:logs:${local.app_region}:${local.account_id}:log-group:/aws/lambda/snacker-tracker-${function}-${ws}"
    ]
  ])
}

data "aws_iam_policy_document" "reporter_serverless_runtime_boundary" {
  statement {
    sid = "Bucket"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
    ]
    resources = local.reporter_serverless_buckets
  }

  statement {
    sid = "Objects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = [for bucket in local.reporter_serverless_buckets : "${bucket}/*"]
  }

  statement {
    sid       = "PutRecords"
    actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
    resources = local.reporter_serverless_streams
  }

  statement {
    sid       = "PutEvents"
    actions   = ["events:PutEvents"]
    resources = local.reporter_serverless_buses
  }

  statement {
    sid = "ConsumeQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = local.reporter_serverless_queues
  }

  statement {
    sid       = "DeadLetters"
    actions   = ["sqs:SendMessage"]
    resources = local.reporter_serverless_dlqs
  }

  # CreateLogGroup is authorized against the group, the others against its streams.
  statement {
    sid = "FunctionLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = concat(
      local.reporter_serverless_log_groups,
      [for group in local.reporter_serverless_log_groups : "${group}:*"],
    )
  }
}

import {
  to = module.baseline.aws_iam_policy.managed["app-role-permissions-boundary"]
  id = "arn:aws:iam::${local.account_id}:policy/app-role-permissions-boundary"
}

import {
  to = module.baseline.aws_iam_policy.managed["runtime-role-permissions-boundary"]
  id = "arn:aws:iam::${local.account_id}:policy/runtime-role-permissions-boundary"
}

import {
  to = module.baseline.aws_iam_policy.managed["reporter-serverless-runtime-boundary"]
  id = "arn:aws:iam::${local.account_id}:policy/reporter-serverless-runtime-boundary"
}
