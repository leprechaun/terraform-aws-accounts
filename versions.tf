terraform {
  # >= 1.10 for native S3 state locking (use_lockfile) instead of a
  # separate DynamoDB lock table.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend blocks can't reference variables, so profile/region/bucket are
  # hardcoded here rather than pulled from terraform.tfvars.
  backend "s3" {
    bucket       = "lmacguire-terraform"
    key          = "terraform-aws-accounts/terraform.tfstate"
    region       = "ap-southeast-1"
    profile      = "lmac"
    encrypt      = true
    use_lockfile = true
  }
}
