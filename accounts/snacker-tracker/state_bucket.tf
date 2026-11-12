# The bucket snacker-tracker's app repos keep their Terraform state in
# (interface's and reporter-serverless's deploy roles have grants on it, in
# app_roles.tf). It used to hold snacker-tracker/aws-infra's own state too,
# which is where its name comes from. The apps' state is moving into
# lmacguire-terraform (app_state_bucket_arn in app_roles.tf); once it has,
# this bucket goes.

resource "aws_s3_bucket" "state" {
  provider = aws.app

  bucket = "snacker-tracker-aws-infra-tfstate"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  provider = aws.app

  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  provider = aws.app

  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  provider = aws.app

  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

import {
  provider = aws.app
  to       = aws_s3_bucket.state
  id       = "snacker-tracker-aws-infra-tfstate"
}

import {
  provider = aws.app
  to       = aws_s3_bucket_versioning.state
  id       = "snacker-tracker-aws-infra-tfstate"
}

import {
  provider = aws.app
  to       = aws_s3_bucket_server_side_encryption_configuration.state
  id       = "snacker-tracker-aws-infra-tfstate"
}

import {
  provider = aws.app
  to       = aws_s3_bucket_public_access_block.state
  id       = "snacker-tracker-aws-infra-tfstate"
}
