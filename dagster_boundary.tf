# Permissions boundary for the dagster IAM user, which the management-aws
# pipeline creates and manages itself. That pipeline can only create or change
# the user with this boundary attached, so whatever policies it puts on the
# user, the user can never do more than this. Change it here, not in
# terraform-aws-management.
#
# S3 object access only, account-wide: the stack's own policy narrows it to
# specific buckets. Tighten this to named buckets once they're settled.

locals {
  dagster_user_arn      = "arn:aws:iam::${var.owner_account_id}:user/dagster"
  dagster_boundary_name = "dagster-boundary"
  dagster_boundary_arn  = "arn:aws:iam::${var.owner_account_id}:policy/${local.dagster_boundary_name}"
}

data "aws_iam_policy_document" "dagster_boundary" {
  statement {
    sid    = "S3Objects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::*"]
  }
}

resource "aws_iam_policy" "dagster_boundary" {
  name        = local.dagster_boundary_name
  description = "Permissions boundary for the dagster user."
  policy      = data.aws_iam_policy_document.dagster_boundary.json

  tags = {
    Project   = "management-aws"
    Component = "dagster"
  }

  # Apply needs its ManageDagsterBoundary statement before it can create this.
  depends_on = [aws_iam_role_policy.github_actions]
}

output "dagster_boundary_arn" {
  description = "Permissions boundary terraform-aws-management must set on the dagster user."
  value       = aws_iam_policy.dagster_boundary.arn
}
