locals {
  # The management stack's lmac_sh_account_id output. Also in
  # .github/workflows/terraform.yml. Empty until the account exists, which
  # makes the provider refuse to run.
  account_id = ""
}

# No assume_role: CI logs straight into this account with the baseline's
# roles, and local runs use an SSO profile for it (see README).
provider "aws" {
  region = "us-east-1"

  allowed_account_ids = [local.account_id]

  default_tags {
    tags = {
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = "git@github.com:leprechaun/terraform-aws-accounts"
      Project     = "shared-infra"
      Component   = "shared-infra"
    }
  }
}
