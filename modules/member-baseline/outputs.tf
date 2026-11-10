output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "terraform_role_arn" {
  value = aws_iam_role.terraform.arn
}

output "terraform_plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}

output "managed_policy_arns" {
  value = { for name, policy in aws_iam_policy.managed : name => policy.arn }
}

output "github_role_arns" {
  value = { for key, role in aws_iam_role.github : key => role.arn }
}
