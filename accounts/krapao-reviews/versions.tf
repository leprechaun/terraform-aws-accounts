terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # In the management account's state bucket, which the baseline's roles reach
  # through its bucket policy (terraform_state_bucket.tf).
  backend "s3" {
    bucket       = "lmacguire-terraform"
    key          = "member-accounts/krapao-reviews/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
