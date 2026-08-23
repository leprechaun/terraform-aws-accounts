# Existing CloudTrail setup — must be imported, not created. See README.
# Trail lives in ap-southeast-1 (its home region); the S3 bucket it
# delivers to lives in us-east-1. Dedicated bucket, nothing else uses it.

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "lmacguire-aws-logs"

  lifecycle {
    # Audit log bucket — never let a stray destroy take out log history.
    prevent_destroy = true
  }
}

# Confirmed to match the real bucket policy exactly via
# `aws s3api get-bucket-policy --bucket lmacguire-aws-logs` — same Sids,
# same conditions, same resource ARNs. Not a guess.
data "aws_iam_policy_document" "cloudtrail_logs" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:ap-southeast-1:${var.owner_account_id}:trail/Default"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${var.owner_account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:ap-southeast-1:${var.owner_account_id}:trail/Default"]
    }
  }

  # Organization trails deliver member-account logs under an org-ID-prefixed
  # path (AWSLogs/<org-id>/<account-id>/...) instead of the plain
  # AWSLogs/<account-id>/... path the management account's own logs use
  # above — this statement is additive, not a replacement, since existing
  # history stays under the old path.
  statement {
    sid    = "AWSCloudTrailWriteOrg"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${aws_organizations_organization.this.id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:ap-southeast-1:${var.owner_account_id}:trail/Default"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_logs.json
}

# Values below confirmed via `aws cloudtrail get-trail` /
# `get-event-selectors` against the real trail — not guesses. Notably
# is_multi_region_trail must be explicit: the provider's own default is
# false, which would otherwise silently try to turn off multi-region
# coverage on a live trail (this is what caused the earlier
# CloudTrailAccessNotEnabledException on apply).
#
# is_organization_trail = true requires aws_service_access_principals on
# aws_organizations_organization.this to already include cloudtrail — the
# explicit depends_on below ensures that lands first, not just implicitly
# via provider ordering.
resource "aws_cloudtrail" "default" {
  provider = aws.ap_southeast_1

  name           = "Default"
  s3_bucket_name = aws_s3_bucket.cloudtrail_logs.id

  include_global_service_events = true
  is_multi_region_trail         = true
  is_organization_trail         = true

  # Turns on CloudTrail's log file integrity validation: hourly signed
  # digest files chained to prior digests, letting `aws cloudtrail
  # validate-logs` prove the delivered log files haven't been modified,
  # deleted, or added out of band since delivery. Free, no functional
  # downside, and exactly the guarantee an audit trail bucket should have —
  # there was no reason found for this having been off.
  enable_log_file_validation = true

  # Matches the real trail's single default event selector (all management
  # events, no data resources) — omitting this block entirely would also
  # match, but being explicit avoids relying on provider-default behavior.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_logs,
    aws_organizations_organization.this,
  ]
}
