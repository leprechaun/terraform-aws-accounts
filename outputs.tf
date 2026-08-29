output "organization_id" {
  value = aws_organizations_organization.this.id
}

output "organization_root_id" {
  value = aws_organizations_organization.this.roots[0].id
}

output "existing_account_id" {
  value = aws_organizations_account.lmacguire-sub-01.id
}

output "snacker_tracker_account_id" {
  value = aws_organizations_account.snacker-tracker.id
}

output "snacker_tracker_account_access_role_arn" {
  description = "Role to assume from the owner account to operate inside the new sub-account."
  value       = "arn:aws:iam::${aws_organizations_account.snacker-tracker.id}:role/OrganizationAccountAccessRole"
}

output "krapao_reviews_account_id" {
  value = aws_organizations_account.krapao-reviews.id
}

output "krapao_reviews_account_access_role_arn" {
  description = "Role to assume from the owner account to operate inside the krapao-reviews sub-account."
  value       = "arn:aws:iam::${aws_organizations_account.krapao-reviews.id}:role/OrganizationAccountAccessRole"
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub Actions."
  value       = aws_iam_role.github_actions.arn
}

output "github_actions_plan_role_arn" {
  description = "Set this as the AWS_PLAN_ROLE_ARN repository variable in GitHub Actions."
  value       = aws_iam_role.github_actions_plan.arn
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.default.arn
}

output "krapao_reviews_github_actions_role_arn" {
  value = aws_iam_role.krapao_reviews_github_actions.arn
}

output "personal_domain_zone_id" {
  value     = aws_route53_zone.personal_domain.zone_id
  sensitive = true
}

output "personal_domain_name_servers" {
  description = "Set these as the NS records at the registrar to actually delegate the domain to this zone. Run `terraform output personal_domain_name_servers` to reveal — sensitive outputs are redacted from plan/apply/CI output by default."
  value       = aws_route53_zone.personal_domain.name_servers
  sensitive   = true
}
