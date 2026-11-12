# The S3 backend bucket from versions.tf — existing, so imported rather than
# created. Holds this repo's own state and every other repo's too, which is
# why the CI roles get a narrower grant on it than the other buckets here
# (TerraformStateBucketConfig in github_oidc.tf): no s3:DeleteBucket, no
# changing versioning/encryption. The bucket itself is managed mainly to get
# default_tags onto it, and its policy for the member-account stacks below.
# Versioning, encryption and the public access block stay configured outside
# Terraform.
#
# Deliberately not a bootstrap: this can't create the bucket it stores its
# own state in. A fresh setup still creates the bucket by hand first.

resource "aws_s3_bucket" "terraform_state" {
  provider = aws.ap_southeast_1

  bucket = "lmacguire-terraform"

  lifecycle {
    # Losing this bucket loses the state of every repo stored in it.
    prevent_destroy = true
  }
}

# Member-account stacks write their state with roles from their own
# account, and without this the writing account owns the object, so the
# management account couldn't read it (bootstrap mode, recovery). With it,
# ACLs are off and the bucket owner owns every object, existing ones too.
resource "aws_s3_bucket_ownership_controls" "terraform_state" {
  provider = aws.ap_southeast_1

  bucket = aws_s3_bucket.terraform_state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }

  # Applied by CI, whose permission for it is in the same apply.
  depends_on = [aws_iam_role_policy.github_actions]
}

# Member-account stacks (accounts/<name>) run with roles inside their own
# account, so reaching their state here needs this as well as their own
# identity policies (modules/member-baseline). Each account only gets its
# own prefix. Matched on aws:PrincipalArn rather than listed as principals,
# because S3 rejects a policy naming a role that doesn't exist yet, and a
# recreated role would silently stop matching a principal entry.
locals {
  member_accounts = {
    krapao-reviews   = aws_organizations_account.krapao-reviews.id
    lmac-sh          = aws_organizations_account.lmac-sh.id
    lmacguire-sub-01 = aws_organizations_account.lmacguire-sub-01.id
    snacker-tracker  = aws_organizations_account.snacker-tracker.id
  }

  # Workload repos' stacks in member accounts, each under its own prefix, as
  # its S3 backend lays them out: the default workspace at
  # <prefix>/terraform.tfstate (key = that), other workspaces at
  # <prefix>/<workspace>/terraform.tfstate (key = "terraform.tfstate",
  # workspace_key_prefix = <prefix>). Writers apply, readers only plan; both
  # can lock and list the prefix. Principals are ARN patterns, matched with
  # ArnLike.
  workload_states = {
    lmac-sh-site = {
      prefix = "member-accounts/lmac-sh/site"
      workspaces = {
        default = {
          writers = ["arn:aws:iam::${aws_organizations_account.lmac-sh.id}:role/github-site"]
          readers = ["arn:aws:iam::${aws_organizations_account.lmac-sh.id}:role/github-site-plan"]
        }
      }
    }

    # Applied by CI, one role per environment.
    snacker-tracker-interface = {
      prefix = "member-accounts/snacker-tracker/interface"
      workspaces = {
        for env in ["dev", "prod"] : env => {
          writers = ["arn:aws:iam::${aws_organizations_account.snacker-tracker.id}:role/github-actions-interface-${env}", local.snacker_tracker_admin]
          readers = []
        }
      }
    }

    # Interface's IAM and buckets, which an admin applies by hand.
    snacker-tracker-interface-admin = {
      prefix = "member-accounts/snacker-tracker/interface-admin"
      workspaces = {
        for env in ["dev", "prod"] : env => { writers = [local.snacker_tracker_admin], readers = [] }
      }
    }

    # Applied by CI, one role for both environments.
    snacker-tracker-reporter-serverless = {
      prefix = "member-accounts/snacker-tracker/reporter-serverless"
      workspaces = {
        for env in ["dev", "prod"] : env => {
          writers = ["arn:aws:iam::${aws_organizations_account.snacker-tracker.id}:role/github-actions-reporter-serverless-deploy", local.snacker_tracker_admin]
          readers = []
        }
      }
    }

    # Interface's stepdag/examples/hello, applied by hand.
    snacker-tracker-stepdag-hello = {
      prefix = "member-accounts/snacker-tracker/stepdag-hello"
      workspaces = {
        dev = { writers = [local.snacker_tracker_admin], readers = [] }
      }
    }
  }

  # Whoever has the account's AdministratorAccess permission set: the hand
  # applies, and fixing a CI stack's state (unlocking, moving resources).
  snacker_tracker_admin = "arn:aws:iam::${aws_organizations_account.snacker-tracker.id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AdministratorAccess_*"

  # One per state object, keyed for its Sids.
  workload_state_objects = merge([
    for name, state in local.workload_states : {
      for workspace, access in state.workspaces : (workspace == "default" ? name : "${name}-${workspace}") => {
        key     = workspace == "default" ? "${state.prefix}/terraform.tfstate" : "${state.prefix}/${workspace}/terraform.tfstate"
        writers = access.writers
        readers = access.readers
      }
    }
  ]...)
}

data "aws_iam_policy_document" "terraform_state" {
  dynamic "statement" {
    for_each = local.member_accounts

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}State"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject"]
      resources = ["${aws_s3_bucket.terraform_state.arn}/member-accounts/${statement.key}/terraform.tfstate"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = ["arn:aws:iam::${statement.value}:role/terraform-aws-accounts"]
      }
    }
  }

  dynamic "statement" {
    for_each = local.member_accounts

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}StateRead"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.terraform_state.arn}/member-accounts/${statement.key}/terraform.tfstate"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = ["arn:aws:iam::${statement.value}:role/terraform-aws-accounts-plan"]
      }
    }
  }

  dynamic "statement" {
    for_each = local.member_accounts

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}StateLock"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.terraform_state.arn}/member-accounts/${statement.key}/terraform.tfstate.tflock"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values = [
          "arn:aws:iam::${statement.value}:role/terraform-aws-accounts",
          "arn:aws:iam::${statement.value}:role/terraform-aws-accounts-plan",
        ]
      }
    }
  }

  dynamic "statement" {
    for_each = local.member_accounts

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}StateList"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.terraform_state.arn]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values = [
          "arn:aws:iam::${statement.value}:role/terraform-aws-accounts",
          "arn:aws:iam::${statement.value}:role/terraform-aws-accounts-plan",
        ]
      }

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["member-accounts/${statement.key}/*", "env:/*"]
      }
    }
  }

  dynamic "statement" {
    for_each = local.workload_state_objects

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}State"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject"]
      resources = ["${aws_s3_bucket.terraform_state.arn}/${statement.value.key}"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:PrincipalArn"
        values   = statement.value.writers
      }
    }
  }

  dynamic "statement" {
    for_each = { for name, object in local.workload_state_objects : name => object if length(object.readers) > 0 }

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}StateRead"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.terraform_state.arn}/${statement.value.key}"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:PrincipalArn"
        values   = statement.value.readers
      }
    }
  }

  dynamic "statement" {
    for_each = local.workload_state_objects

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}StateLock"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.terraform_state.arn}/${statement.value.key}.tflock"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:PrincipalArn"
        values   = concat(statement.value.writers, statement.value.readers)
      }
    }
  }

  # The backend lists the prefix to find the workspaces, which shows each
  # one's key but none of its contents.
  dynamic "statement" {
    for_each = local.workload_states

    content {
      sid       = "${replace(title(replace(statement.key, "-", " ")), " ", "")}StateList"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.terraform_state.arn]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:PrincipalArn"
        values   = distinct(flatten([for access in values(statement.value.workspaces) : concat(access.writers, access.readers)]))
      }

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["${statement.value.prefix}/*"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "terraform_state" {
  provider = aws.ap_southeast_1

  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json
}
