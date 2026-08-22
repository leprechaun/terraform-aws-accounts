terraform {
  # >= 1.10 for native S3 state locking (use_lockfile) instead of a
  # separate DynamoDB lock table.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Backend blocks can't reference variables, so bucket/region are hardcoded
  # rather than pulled from terraform.tfvars. No `profile` here on purpose:
  # it can't be conditional, and CI has no "lmac" profile. Both local runs
  # and CI authenticate via the standard AWS credential chain instead —
  # locally, export AWS_PROFILE=lmac before running terraform (see README).
  backend "s3" {
    bucket       = "lmacguire-terraform"
    key          = "terraform-aws-accounts/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
