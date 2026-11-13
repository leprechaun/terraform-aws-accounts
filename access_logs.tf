# Where every account's web access logs go, so they can be queried in one
# place (Athena, later). Not the CloudTrail bucket: that one is audit-only,
# with a policy scoped to the trail, and nothing here should be able to touch
# it.
#
# CloudFront standard logging v2 (a CloudWatch vended-logs delivery to S3)
# writes here from any account in the org. v2 rather than the legacy kind:
# legacy logging needs ACLs, which this bucket keeps off. Delivering across
# accounts takes three things: this bucket's policy, a delivery destination
# here for each account (below), and the account's own delivery source and
# delivery, which live in each site's repo and point at that account's
# destination. Leave the suffix path at its default and objects land under
# AWSLogs/<account-id>/CloudFront/..., which is already partitioned by
# account for a table over the whole bucket.

locals {
  access_logs_bucket_name = "lmacguire-access-logs"

  # Every account that may deliver logs, the management account included.
  access_log_accounts = merge(local.member_accounts, { management = var.owner_account_id })

  access_logs_retention_days = 365
}

resource "aws_s3_bucket" "access_logs" {
  bucket = local.access_logs_bucket_name

  lifecycle {
    # Not audit data, but there's no way to get it back.
    prevent_destroy = true
  }

  # Applied by CI, whose permission for it is in the same apply. Everything
  # else here waits on the bucket, so this orders the lot.
  depends_on = [aws_iam_role_policy.github_actions]
}

# ACLs off, the bucket owner owns every object, whichever account's delivery
# wrote it.
resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 rather than a KMS key: log delivery to a KMS-encrypted bucket needs
# the key's policy to trust the delivery service in every account as well.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = local.access_logs_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "access_logs" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.access_logs.arn,
      "${aws_s3_bucket.access_logs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Each account can only write under its own AWSLogs/<account-id>/, and only
  # through a delivery of its own, so one account can't fill or overwrite
  # another's logs.
  dynamic "statement" {
    for_each = local.access_log_accounts

    content {
      sid    = "LogDeliveryWrite${replace(title(statement.key), "-", "")}"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }

      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.access_logs.arn}/AWSLogs/${statement.value}/*"]

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [statement.value]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = ["arn:aws:logs:*:${statement.value}:delivery-source:*"]
      }
    }
  }

  statement {
    sid    = "LogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.access_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = values(local.access_log_accounts)
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [for id in values(local.access_log_accounts) : "arn:aws:logs:*:${id}:delivery-source:*"]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json

  # The public access block rejects a policy applied while it's still being
  # created.
  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}

# One destination per account, so the policy on each can name just that
# account. Vended-logs deliveries are a us-east-1 API for CloudFront whatever
# region the bucket is in; the default provider is us-east-1. The output
# format can't be changed once a destination exists: a different one means
# replacing it, and its deliveries with it. JSON needs no conversion charge,
# unlike Parquet.
resource "aws_cloudwatch_log_delivery_destination" "access_logs" {
  for_each = local.access_log_accounts

  name          = "access-logs-${each.key}"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.access_logs.arn
  }

  depends_on = [aws_s3_bucket_policy.access_logs]
}

# Lets each member account create a delivery to its own destination, and
# nothing else. The management account's deliveries are same-account and
# need no policy.
data "aws_iam_policy_document" "access_log_delivery" {
  for_each = local.member_accounts

  statement {
    sid    = "AllowCreateDelivery"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [each.value]
    }

    actions   = ["logs:CreateDelivery"]
    resources = [aws_cloudwatch_log_delivery_destination.access_logs[each.key].arn]
  }
}

resource "aws_cloudwatch_log_delivery_destination_policy" "access_logs" {
  for_each = local.member_accounts

  delivery_destination_name   = aws_cloudwatch_log_delivery_destination.access_logs[each.key].name
  delivery_destination_policy = data.aws_iam_policy_document.access_log_delivery[each.key].json
}
