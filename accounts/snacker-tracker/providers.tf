locals {
  # The management stack's snacker_tracker_account_id output. Also in
  # .github/workflows/terraform.yml.
  account_id = "132218943709"

  default_tags = {
    Environment = "shared"
    ManagedBy   = "terraform"
    Repository  = "git@github.com:leprechaun/terraform-aws-accounts"
    # As snacker-tracker/aws-infra tagged them, since most of what's here
    # came from there.
    Project   = "snacker-tracker"
    Component = "base-infra"
  }
}

# Normally no assume_role: CI logs straight into this account with the
# baseline's roles. With bootstrap = true, it runs with your local
# management-account credentials instead and assumes
# OrganizationAccountAccessRole, for the first apply that creates those roles
# (see README).
provider "aws" {
  region = "us-east-1"

  allowed_account_ids = [local.account_id]

  dynamic "assume_role" {
    for_each = var.bootstrap ? [1] : []

    content {
      role_arn     = "arn:aws:iam::${local.account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-aws-accounts-bootstrap"
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

# Where the apps run, and so their ECR repositories and state bucket.
provider "aws" {
  alias  = "app"
  region = local.app_region

  allowed_account_ids = [local.account_id]

  dynamic "assume_role" {
    for_each = var.bootstrap ? [1] : []

    content {
      role_arn     = "arn:aws:iam::${local.account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-aws-accounts-bootstrap"
    }
  }

  default_tags {
    tags = local.default_tags
  }
}
