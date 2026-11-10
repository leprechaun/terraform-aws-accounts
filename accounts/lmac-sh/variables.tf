variable "site_domain_name" {
  description = "Not committed, like personal_domain_name in the management stack: locally in secrets.auto.tfvars.json (gitignored), in CI from the MEMBER_TFVARS_LMAC_SH secret."
  type        = string
  sensitive   = true
}
