# GitHub Actions deploy role for leprechaun/kbank-email-notifications-lambda.
# Its pipeline runs `terraform apply` on that repo's infra/ directory, so these
# permissions mirror what infra/main.tf manages there.

locals {
  kbank_email_notifications_github_actions_role_name = "kbank-email-notifications-github-actions"
  kbank_email_notifications_region                   = "eu-west-1"
  kbank_email_notifications_function_arn_pattern     = "arn:aws:lambda:${local.kbank_email_notifications_region}:${var.owner_account_id}:function:kbank-email-notifications-*"
}

data "aws_iam_policy_document" "kbank_email_notifications_github_actions_assume_role" {
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

    # Only the deploy-dev and deploy-prod jobs, which set `environment:`.
    #
    # Unlike this repo's own CI roles, this is the plain-name sub claim, not
    # the immutable-ID form: GET /repos/OWNER/REPO/actions/oidc/customization/sub
    # reports use_immutable_subject = false for this older repo.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun/kbank-email-notifications-lambda:environment:dev",
        "repo:leprechaun/kbank-email-notifications-lambda:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "kbank_email_notifications_github_actions" {
  name               = local.kbank_email_notifications_github_actions_role_name
  assume_role_policy = data.aws_iam_policy_document.kbank_email_notifications_github_actions_assume_role.json

  tags = {
    Project   = "kbank-email-notifications"
    Component = "deploy"
  }

  # Apply runs as aws_iam_role.github_actions, which needs its
  # ManageKbankEmailNotificationsGithubActionsRole statement in place before
  # it can create this role. That statement names the ARN by string rather
  # than referencing this resource, which would order them the wrong way.
  depends_on = [aws_iam_role_policy.github_actions]
}

data "aws_iam_policy_document" "kbank_email_notifications_github_actions_deploy" {
  # infra/main.tf's backend: key "kbank-notifications", under the default
  # "env:" workspace prefix for the dev and prod workspaces.
  statement {
    sid     = "TerraformStateObjects"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::lmacguire-terraform/kbank-notifications*",
      "arn:aws:s3:::lmacguire-terraform/env:/*/kbank-notifications*",
    ]
  }

  # `terraform workspace select` lists every workspace under "env:/", so this
  # exposes other projects' workspace key names, but not their contents.
  statement {
    sid       = "TerraformStateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::lmacguire-terraform"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["kbank-notifications*", "env:/*"]
    }
  }

  # Queue management only: no SendMessage/ReceiveMessage, so the pipeline
  # can't read the transaction data passing through these queues.
  statement {
    sid    = "Sqs"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ListQueueTags",
      "sqs:SetQueueAttributes",
      "sqs:TagQueue",
      "sqs:UntagQueue",
    ]
    resources = [
      "arn:aws:sqs:${local.kbank_email_notifications_region}:${var.owner_account_id}:kbank-parsed-notifications-*",
      "arn:aws:sqs:${local.kbank_email_notifications_region}:${var.owner_account_id}:ses-incoming-notifications-*",
    ]
  }

  # Get*/List* rather than enumerating them, for the same reason as
  # CloudTrailAndCostExportBuckets in github_oidc.tf: the read set is long and
  # provider-version-dependent.
  statement {
    sid    = "LambdaFunction"
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
      local.kbank_email_notifications_function_arn_pattern,
      "${local.kbank_email_notifications_function_arn_pattern}:*",
    ]
  }

  # Mapping UUIDs aren't known up front, so these are scoped by the function
  # they point at instead of by ARN.
  statement {
    sid    = "LambdaEventSourceMappingWrite"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "lambda:FunctionArn"
      values   = [local.kbank_email_notifications_function_arn_pattern]
    }
  }

  statement {
    sid       = "LambdaEventSourceMappingRead"
    effect    = "Allow"
    actions   = ["lambda:GetEventSourceMapping"]
    resources = ["arn:aws:lambda:${local.kbank_email_notifications_region}:${var.owner_account_id}:event-source-mapping:*"]
  }

  statement {
    sid    = "LambdaExecutionRole"
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
    resources = ["arn:aws:iam::${var.owner_account_id}:role/kbank-lambda-sqs-role-*"]
  }

  statement {
    sid       = "LambdaExecutionRoleManagedPolicy"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${var.owner_account_id}:role/kbank-lambda-sqs-role-*"]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"]
    }
  }

  statement {
    sid       = "LambdaExecutionRolePass"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.owner_account_id}:role/kbank-lambda-sqs-role-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "kbank_email_notifications_github_actions_deploy" {
  name   = "deploy"
  role   = aws_iam_role.kbank_email_notifications_github_actions.id
  policy = data.aws_iam_policy_document.kbank_email_notifications_github_actions_deploy.json
}
