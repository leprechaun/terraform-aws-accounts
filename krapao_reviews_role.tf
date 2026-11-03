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

    # Only the deploy-dev and deploy-prod jobs, which set `environment:`. These
    # are the only subjects CloudTrail shows assuming this role, in the
    # plain-name form rather than the immutable-ID one.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun/krapao-reviews:environment:dev",
        "repo:leprechaun/krapao-reviews:environment:prod",
      ]
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

# Originally written from the real inline policy via
# `aws iam get-role-policy --role-name krapao-reviews-github-actions
# --policy-name deploy`. The state statements have since been narrowed from
# the whole bucket to this project's own keys.
data "aws_iam_policy_document" "krapao_reviews_github_actions_deploy" {
  # infra/backend.tf: key "terraform.tfstate" under workspace_key_prefix
  # "krapao-reviews". The pipeline must set TF_WORKSPACE, so init never reads
  # the default workspace's key at the bucket root, which this role can't.
  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/krapao-reviews/*/terraform.tfstate"]
  }

  # The backend doesn't set use_lockfile yet; this is ready for when it does.
  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::lmacguire-terraform/krapao-reviews/*/terraform.tfstate.tflock"]
  }

  # Enumerating workspaces lists workspace_key_prefix.
  statement {
    sid       = "TerraformStateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::lmacguire-terraform"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["krapao-reviews/*"]
    }
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
