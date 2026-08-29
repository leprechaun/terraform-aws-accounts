# A second, read-only GitHub Actions role for `terraform plan` — used by the
# single unattended plan job that now runs on every push, to every branch
# (see .github/workflows/terraform.yml), which should never hold credentials
# capable of changing anything. Only the environment:prod-gated apply job
# assumes the full read/write role in github_oidc.tf.

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

    # The plan job has no `environment:` set, so it always gets a ref-scoped
    # claim (repo:OWNER/REPO:ref:refs/heads/BRANCH) rather than an
    # environment-scoped one — and since it now runs on push of every
    # branch, not just master, this is a wildcard across all branch refs
    # rather than one fixed value. See github_oidc.tf for the equivalent
    # environment:prod-only condition on the apply-capable role — broadening
    # this one doesn't broaden that one, since apply is gated by environment
    # rather than by branch ref.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun@355637/terraform-aws-accounts@1343063405:ref:refs/heads/*",
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

  # dns.tf's hosted zone(s). Zone IDs are AWS-generated, not chosen at
  # create time, so there's no ARN to scope to until after a zone already
  # exists — "*" for consistency with the same tradeoff elsewhere in this
  # file, not because scoping was skipped.
  statement {
    sid       = "Route53Read"
    effect    = "Allow"
    actions   = ["route53:Get*", "route53:List*"]
    resources = ["*"]
  }

  # cost_allocation_tags.tf's aws_ce_cost_allocation_tag resources — Cost
  # Explorer doesn't support resource-level ARN scoping here either, same
  # tradeoff as the other billing/org-wide services above.
  statement {
    sid       = "CostAllocationTagsRead"
    effect    = "Allow"
    actions   = ["ce:ListCostAllocationTags"]
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
