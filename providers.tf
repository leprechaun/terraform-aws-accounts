provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Organizations, account management, etc. must always run against the
  # management (owner) account. The check block in organization.tf verifies
  # this profile actually resolves to var.owner_account_id before anything
  # else runs.
  allowed_account_ids = [var.owner_account_id]
}
