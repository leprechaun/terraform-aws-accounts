# GitHub Actions deploy role for the krapao-reviews repo/project. Existing
# role, previously managed by a different Terraform state — must be
# imported, not created. See README: the OLD state needs `terraform state
# rm` (not destroy) on this role as part of the move, or both configs will
# fight over it.

data "aws_iam_policy_document" "krapao_reviews_github_actions_assume_role" {
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

    # Unlike this repo's own CI role, this trusts the entire
    # leprechaun/krapao-reviews repo (any branch, any event) rather than
    # scoping to specific PR/environment subjects — matches the real trust
    # policy, not a tightened guess.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:leprechaun/krapao-reviews:*"]
    }
  }
}

resource "aws_iam_role" "krapao_reviews_github_actions" {
  name                 = "krapao-reviews-github-actions"
  path                 = "/"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.krapao_reviews_github_actions_assume_role.json

  tags = {
    Project     = "krapao-reviews"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# Confirmed to match the real inline policy exactly via
# `aws iam get-role-policy --role-name krapao-reviews-github-actions
# --policy-name deploy` — same Sids, same actions, same resources. Not a
# guess.
data "aws_iam_policy_document" "krapao_reviews_github_actions_deploy" {
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:GetBucketVersioning",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::lmacguire-terraform/*",
      "arn:aws:s3:::lmacguire-terraform",
    ]
  }

  statement {
    sid       = "SiteBuckets"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::krapao-reviews-*/*", "arn:aws:s3:::krapao-reviews-*"]
  }

  statement {
    sid       = "CloudFront"
    effect    = "Allow"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ACM"
    effect    = "Allow"
    actions   = ["acm:*"]
    resources = ["*"]
  }

  statement {
    sid       = "Route53"
    effect    = "Allow"
    actions   = ["route53:*"]
    resources = ["*"]
  }

  statement {
    sid    = "IAMOidc"
    effect = "Allow"
    actions = [
      "iam:UpdateOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:CreateOpenIDConnectProvider",
    ]
    resources = ["arn:aws:iam::${var.owner_account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }

  statement {
    sid    = "IAMRole"
    effect = "Allow"
    actions = [
      "iam:TagRole",
      "iam:PutRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListAttachedRolePolicies",
      "iam:GetRolePolicy",
      "iam:GetRole",
      "iam:DeleteRolePolicy",
      "iam:DeleteRole",
      "iam:CreateRole",
    ]
    resources = ["arn:aws:iam::${var.owner_account_id}:role/krapao-reviews-*"]
  }
}

resource "aws_iam_role_policy" "krapao_reviews_github_actions_deploy" {
  name   = "deploy"
  role   = aws_iam_role.krapao_reviews_github_actions.id
  policy = data.aws_iam_policy_document.krapao_reviews_github_actions_deploy.json
}
