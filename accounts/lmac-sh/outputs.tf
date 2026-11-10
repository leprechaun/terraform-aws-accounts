output "site_zone_id" {
  value = aws_route53_zone.site.zone_id
}

output "site_name_servers" {
  description = "Set these at the domain's registrar."
  value       = aws_route53_zone.site.name_servers
}

output "terraform_role_arn" {
  value = module.baseline.terraform_role_arn
}

output "terraform_plan_role_arn" {
  value = module.baseline.terraform_plan_role_arn
}
