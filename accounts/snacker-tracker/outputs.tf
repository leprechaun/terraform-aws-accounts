output "terraform_role_arn" {
  value = module.baseline.terraform_role_arn
}

output "terraform_plan_role_arn" {
  value = module.baseline.terraform_plan_role_arn
}

output "khanom_xyz_zone_id" {
  value = aws_route53_zone.khanom_xyz.zone_id
}

output "khanom_xyz_name_servers" {
  value = aws_route53_zone.khanom_xyz.name_servers
}

# What snacker-tracker/aws-infra used to output, for the repos that use them.

output "github_actions_admin_role_arn" {
  description = "aws-infra's AWS_ROLE_ARN repo variable"
  value       = module.baseline.github_role_arns["actions-admin"]
}

output "github_actions_plan_role_arn" {
  description = "aws-infra's AWS_PLAN_ROLE_ARN repo variable"
  value       = module.baseline.github_role_arns["actions-plan"]
}

output "reporter_serverless_deploy_role_arn" {
  description = "reporter-serverless's AWS_ROLE_ARN repo variable"
  value       = module.baseline.github_role_arns["actions-reporter-serverless-deploy"]
}

output "interface_deploy_role_arns" {
  description = "Per environment: the role interface's deploy.yml assumes"
  value       = { for env in keys(local.interface) : env => module.baseline.github_role_arns["actions-interface-${env}"] }
}

output "runtime_role_boundary_arn" {
  description = "Set as permissions_boundary on every runtime role an app's Terraform creates"
  value       = module.baseline.managed_policy_arns["runtime-role-permissions-boundary"]
}

output "reporter_serverless_runtime_boundary_arn" {
  description = "Set as permissions_boundary on reporter-serverless's runtime roles, replacing runtime_role_boundary_arn"
  value       = module.baseline.managed_policy_arns["reporter-serverless-runtime-boundary"]
}

output "lambda_repository_urls" {
  value = { for name, repository in aws_ecr_repository.lambda : name => repository.repository_url }
}
