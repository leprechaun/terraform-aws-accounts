# What every member account gets: the GitHub OIDC provider, the two roles
# terraform-aws-accounts' member-account pipeline logs in with, and roles
# for workload repos. The pipeline manages its own roles here, so the first
# apply of each account is local (see README).

locals {
  state_prefix = "member-accounts/${var.name}"
}

# AWS validates GitHub's certificate itself now, so no thumbprint.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  lifecycle {
    # Every GitHub role in the account trusts it, CI's own included.
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "terraform_assume_role" {
  for_each = {
    # Same split as the management stack: plan on every branch, apply only
    # from the approval-gated prod environment.
    terraform-aws-accounts      = "environment:prod"
    terraform-aws-accounts-plan = "ref:refs/heads/*"
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.terraform_repo_subject}:${each.value}"]
    }
  }
}

# Admin, because it manages IAM and whatever else the account's directory
# adds; the account is the boundary.
resource "aws_iam_role" "terraform" {
  name               = "terraform-aws-accounts"
  assume_role_policy = data.aws_iam_policy_document.terraform_assume_role["terraform-aws-accounts"].json

  lifecycle {
    # CI logs in with this; losing it means a local apply to get it back.
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "terraform" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ReadOnlyAccess rather than an exact list, since what plan has to refresh
# depends on what each account's directory adds. It does include reading
# object data, so keep secrets out of buckets in member accounts.
resource "aws_iam_role" "terraform_plan" {
  name               = "terraform-aws-accounts-plan"
  assume_role_policy = data.aws_iam_policy_document.terraform_assume_role["terraform-aws-accounts-plan"].json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "terraform_plan" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# The state bucket is in the management account, so this is only half the
# grant; the other half is its bucket policy (terraform_state_bucket.tf).
data "aws_iam_policy_document" "terraform_state" {
  for_each = {
    terraform      = ["s3:GetObject", "s3:PutObject"]
    terraform_plan = ["s3:GetObject"]
  }

  statement {
    sid       = "State"
    effect    = "Allow"
    actions   = each.value
    resources = ["arn:aws:s3:::${var.state_bucket}/${local.state_prefix}/terraform.tfstate"]
  }

  statement {
    sid       = "StateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/${local.state_prefix}/terraform.tfstate.tflock"]
  }

  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.state_prefix}/*", "env:/*"]
    }
  }
}

resource "aws_iam_role_policy" "terraform_state" {
  name   = "terraform-state"
  role   = aws_iam_role.terraform.id
  policy = data.aws_iam_policy_document.terraform_state["terraform"].json
}

resource "aws_iam_role_policy" "terraform_plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.terraform_plan.id
  policy = data.aws_iam_policy_document.terraform_state["terraform_plan"].json
}

resource "aws_iam_policy" "managed" {
  for_each = var.managed_policies

  name   = each.key
  policy = each.value
}

data "aws_iam_policy_document" "github_assume_role" {
  for_each = var.github_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for subject in each.value.subjects : "repo:${each.value.repo}:${subject}"]
    }
  }
}

resource "aws_iam_role" "github" {
  for_each = var.github_roles

  name                 = "github-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_role[each.key].json
  permissions_boundary = each.value.permissions_boundary == null ? null : aws_iam_policy.managed[each.value.permissions_boundary].arn

  lifecycle {
    # Repos' CI variables hold these ARNs, and a recreated role would break
    # them. To retire one, terraform state rm it before dropping its key.
    prevent_destroy = true
  }
}

locals {
  # Keyed by names rather than ARNs: managed policy ARNs aren't known until
  # apply, and for_each keys have to be.
  github_role_attachments = merge(
    {
      for pair in flatten([
        for role, config in var.github_roles : [
          for arn in config.policy_arns : { key = "${role}/${arn}", role = role, arn = arn }
        ]
      ]) : pair.key => pair
    },
    {
      for pair in flatten([
        for role, config in var.github_roles : [
          for name in config.managed_policies : { key = "${role}/managed/${name}", role = role, arn = aws_iam_policy.managed[name].arn }
        ]
      ]) : pair.key => pair
    },
  )

  github_role_inline_policies = {
    for pair in flatten([
      for role, config in var.github_roles : [
        for name, policy in config.inline_policies : { key = "${role}/${name}", role = role, name = name, policy = policy }
      ]
    ]) : pair.key => pair
  }
}

resource "aws_iam_role_policy_attachment" "github" {
  for_each = local.github_role_attachments

  role       = aws_iam_role.github[each.value.role].name
  policy_arn = each.value.arn
}

resource "aws_iam_role_policy" "github" {
  for_each = local.github_role_inline_policies

  name   = each.value.name
  role   = aws_iam_role.github[each.value.role].id
  policy = each.value.policy
}
