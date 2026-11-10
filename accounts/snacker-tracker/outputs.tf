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
