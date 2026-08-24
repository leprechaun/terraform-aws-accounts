# A second, read-only GitHub Actions role for `terraform plan` — used by
# the PR plan job and the unattended push-to-master plan-apply job (see
# .github/workflows/terraform.yml), neither of which should ever hold
# credentials capable of changing anything. Only the environment:prod-gated
# apply job assumes the full read/write role in github_oidc.tf.

data "aws_iam_policy_document" "github_actions_plan_assume_role" {
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

    # Both job shapes that only ever run `terraform plan`: the PR plan job
    # (pull_request) and the push-to-master plan-apply job, which has no
    # `environment:` set and so gets a ref-scoped claim rather than an
    # environment-scoped one. See github_oidc.tf for the equivalent
    # environment:prod-only condition on the apply-capable role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun@355637/terraform-aws-accounts@1343063405:pull_request",
        "repo:leprechaun@355637/terraform-aws-accounts@1343063405:ref:refs/heads/master",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_plan" {
  name               = "github-actions-aws-organizations-plan"
  assume_role_policy = data.aws_iam_policy_document.github_actions_plan_assume_role.json
}

data "aws_iam_policy_document" "github_actions_plan_permissions" {
  statement {
    sid       = "OrganizationsRead"
    effect    = "Allow"
    actions   = ["organizations:Describe*", "organizations:List*"]
    resources = ["*"]
  }

  # Read-only equivalent of SelfManageGithubActionsRole /
  # ManageKrapaoReviewsGithubActionsRole in github_oidc.tf — `plan` refreshes
  # every resource in state, including the apply-capable role, this role
  # itself, and the krapao-reviews role, so it needs Get/List on all three
  # plus the OIDC provider, but never Put/Delete/Tag.
  statement {
    sid    = "ReadGithubActionsRoles"
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      aws_iam_openid_connect_provider.github_actions.arn,
      aws_iam_role.github_actions.arn,
      aws_iam_role.github_actions_plan.arn,
      aws_iam_role.krapao_reviews_github_actions.arn,
    ]
  }

  statement {
    sid       = "Sts"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # Read-only equivalent of CloudTrailAndCostExportBuckets in github_oidc.tf.
  statement {
    sid    = "CloudTrailAndCostExportBucketsRead"
    effect = "Allow"
    actions = [
      "s3:Get*",
      "s3:List*",
    ]
    resources = [
      aws_s3_bucket.cloudtrail_logs.arn,
      "${aws_s3_bucket.cloudtrail_logs.arn}/*",
      aws_s3_bucket.cost_exports.arn,
      "${aws_s3_bucket.cost_exports.arn}/*",
    ]
  }

  statement {
    sid       = "CloudTrailRead"
    effect    = "Allow"
    actions   = ["cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*"]
    resources = ["*"]
  }

  statement {
    sid       = "BcmDataExportsRead"
    effect    = "Allow"
    actions   = ["bcm-data-exports:Get*", "bcm-data-exports:List*"]
    resources = ["*"]
  }

  # identity_center.tf's permission set / account assignments / instance
  # and user lookups — resource-level ARN scoping isn't consistently
  # supported across these actions, same tradeoff as Organizations/
  # CloudTrail/bcm-data-exports above.
  statement {
    sid       = "IdentityCenterRead"
    effect    = "Allow"
    actions   = ["sso:Describe*", "sso:List*", "sso:Get*"]
    resources = ["*"]
  }

  statement {
    sid       = "IdentityStoreRead"
    effect    = "Allow"
    actions   = ["identitystore:Describe*", "identitystore:List*", "identitystore:Get*"]
    resources = ["*"]
  }

  # terraform plan still needs to read the state object and take/release
  # the native S3 lock (use_lockfile in versions.tf) even though it never
  # writes the state itself — Put/Delete are scoped to just the .tflock
  # object, never the real state key.
  statement {
    sid       = "TerraformStateRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/terraform-aws-accounts/*"]
  }

  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/terraform-aws-accounts/terraform.tfstate.tflock"]
  }

  statement {
    sid       = "TerraformStateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::lmacguire-terraform"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["terraform-aws-accounts/*"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.github_actions_plan.id
  policy = data.aws_iam_policy_document.github_actions_plan_permissions.json
}
