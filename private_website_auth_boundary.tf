# Permissions boundary for the private website's auth role, which the
# management-aws pipeline creates and manages itself. That pipeline can only
# create or change the role with this boundary attached, so whatever policies
# it puts on the role, the role can never do more than this. Change it here,
# not in terraform-aws-management.
#
# The role is the private website's Lambda@Edge execution role, and all it
# needs is to write its own logs, which Lambda@Edge sends to
# /aws/lambda/us-east-1.<function> in whichever region served the request.

locals {
  private_website_auth_role_name     = "private-website-auth"
  private_website_auth_function_arn  = "arn:aws:lambda:${local.management_aws_global_region}:${var.owner_account_id}:function:private-website-auth"
  private_website_auth_boundary_name = "private-website-auth-boundary"
  private_website_auth_role_arn      = "arn:aws:iam::${var.owner_account_id}:role/${local.private_website_auth_role_name}"
  private_website_auth_boundary_arn  = "arn:aws:iam::${var.owner_account_id}:policy/${local.private_website_auth_boundary_name}"
  # The private website's origin bucket, private-<domain with dots as dashes>.
  private_website_bucket_name = "private-${replace(var.personal_domain_name, ".", "-")}"
}

data "aws_iam_policy_document" "private_website_auth_boundary" {
  statement {
    sid       = "LambdaLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:${var.owner_account_id}:log-group:/aws/lambda/*"]
  }
}

resource "aws_iam_policy" "private_website_auth_boundary" {
  name        = local.private_website_auth_boundary_name
  description = "Permissions boundary for the ${local.private_website_auth_role_name} role."
  policy      = data.aws_iam_policy_document.private_website_auth_boundary.json

  tags = {
    Project   = "management-aws"
    Component = "private-website"
  }

  # Apply needs its ManagePrivateWebsiteAuthBoundary statement before it can
  # create this.
  depends_on = [aws_iam_role_policy.github_actions]
}

output "private_website_auth_boundary_arn" {
  description = "Permissions boundary terraform-aws-management must set on the private-website-auth role."
  value       = aws_iam_policy.private_website_auth_boundary.arn
}
