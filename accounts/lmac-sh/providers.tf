# No assume_role: CI logs straight into this account with the baseline's
# roles, and local runs use an SSO profile for it (see README).
provider "aws" {
  region = "us-east-1"

  allowed_account_ids = [var.account_id]

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
