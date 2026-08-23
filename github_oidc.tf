# Lets GitHub Actions in leprechaun/terraform-aws-accounts assume an IAM role via
# short-lived OIDC tokens instead of storing long-lived AWS credentials as
# repo secrets.
#
# Bootstrapping note: this role is what CI uses to run terraform, so it has
# to be created by a local `terraform apply` first (with the "lmac" profile)
# before the workflow can use it. See README for the full bootstrap sequence.

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  lifecycle {
    # This is a single account-wide resource per URL — it almost certainly
    # predates this repo and other pipelines/roles likely trust it too.
    # Never let a stray `terraform destroy` here take it out from under them.
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "github_actions_assume_role" {
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

    # Only PR runs (plan) and the production-environment apply job from this
    # exact repo can assume the role — not forks, not other branches. A job
    # with `environment:` set gets a sub claim scoped to that environment
    # (repo:OWNER/REPO:environment:NAME) instead of the usual ref-scoped
    # one, which is why this lists environment:production rather than
    # ref:refs/heads/master for the apply side.
    #
    # GitHub now appends immutable owner/repo IDs to the sub claim (e.g.
    # leprechaun@355637/terraform-aws-accounts@1343063405 instead of plain
    # leprechaun/terraform-aws-accounts) so a renamed/transferred repo can't
    # inherit an old trust relationship. Confirmed via a temporary debug
    # step in the workflow that printed the actual token claims — don't
    # revert this back to the plain-name form.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun@355637/terraform-aws-accounts@1343063405:pull_request",
        "repo:leprechaun@355637/terraform-aws-accounts@1343063405:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-aws-organizations"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid       = "Organizations"
    effect    = "Allow"
    actions   = ["organizations:*"]
    resources = ["*"]
  }

  # Lets CI manage this OIDC provider/role/policy themselves (e.g. adding
  # another repo later), but nothing broader in IAM.
  statement {
    sid    = "SelfManageGithubActionsRole"
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [
      aws_iam_openid_connect_provider.github_actions.arn,
      aws_iam_role.github_actions.arn,
    ]
  }

  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/terraform-aws-accounts/*"]
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

  statement {
    sid       = "Sts"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # Full s3:* rather than enumerating exact Get*/Put* calls: the aws_s3_bucket
  # and aws_s3_bucket_policy resources touch a long, provider-version-
  # dependent set of read APIs on every plan, and getting this wrong means
  # another round of AccessDenied-then-patch in CI. Scoped tightly to just
  # these two buckets, not account-wide, so the blast radius stays small
  # even though the action list doesn't.
  statement {
    sid    = "CloudTrailAndCostExportBuckets"
    effect = "Allow"
    actions = [
      "s3:*",
    ]
    resources = [
      aws_s3_bucket.cloudtrail_logs.arn,
      "${aws_s3_bucket.cloudtrail_logs.arn}/*",
      aws_s3_bucket.cost_exports.arn,
      "${aws_s3_bucket.cost_exports.arn}/*",
    ]
  }

  # DescribeTrails (and other list-type CloudTrail actions) don't support
  # resource-level ARN scoping in IAM regardless of what's requested, so
  # this is account-wide for CloudTrail — same tradeoff as bcm-data-exports
  # below.
  statement {
    sid       = "CloudTrail"
    effect    = "Allow"
    actions   = ["cloudtrail:*"]
    resources = ["*"]
  }

  # bcm-data-exports doesn't reliably support resource-level ARN scoping for
  # its List/Get actions, so this is account-wide for that one service —
  # still far narrower than granting broad admin access.
  statement {
    sid       = "BcmDataExports"
    effect    = "Allow"
    actions   = ["bcm-data-exports:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "terraform-apply"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
