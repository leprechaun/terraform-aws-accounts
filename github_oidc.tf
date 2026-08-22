# Lets GitHub Actions in leprechaun/aws-organizations assume an IAM role via
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

    # Only PR runs (plan) and pushes to master (apply) from this exact repo
    # can assume the role — not forks, not other branches.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:leprechaun/aws-organizations:pull_request",
        "repo:leprechaun/aws-organizations:ref:refs/heads/master",
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
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "terraform-apply"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
