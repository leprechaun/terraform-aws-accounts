# The S3 backend bucket from versions.tf — existing, so imported rather than
# created. Holds this repo's own state and every other repo's too, which is
# why the CI roles get a narrower grant on it than the other buckets here
# (TerraformStateBucketConfig in github_oidc.tf): no s3:DeleteBucket, no
# changing versioning/encryption/policy. Only the bucket itself is managed,
# mainly to get default_tags onto it. Versioning, encryption and the public
# access block stay configured outside Terraform.
#
# Deliberately not a bootstrap: this can't create the bucket it stores its
# own state in. A fresh setup still creates the bucket by hand first.

# Safe to delete once applied, same as any import block.
import {
  provider = aws.ap_southeast_1
  to       = aws_s3_bucket.terraform_state
  id       = "lmacguire-terraform"
}

resource "aws_s3_bucket" "terraform_state" {
  provider = aws.ap_southeast_1

  bucket = "lmacguire-terraform"

  lifecycle {
    # Losing this bucket loses the state of every repo stored in it.
    prevent_destroy = true
  }
}
