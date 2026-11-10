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

# Member-account stacks (accounts/<name>) run with roles inside their own
# account, so reaching their state here needs this as well as their own
# identity policies (modules/member-baseline). Each account only gets its
# own prefix. Matched on aws:PrincipalArn rather than listed as principals,
# because S3 rejects a policy naming a role that doesn't exist yet, and a
# recreated role would silently stop matching a principal entry.
locals {
  member_accounts = {
    lmac-sh = aws_organizations_account.lmac-sh.id
  }
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
}

resource "aws_s3_bucket_policy" "terraform_state" {
  provider = aws.ap_southeast_1

  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json
}
