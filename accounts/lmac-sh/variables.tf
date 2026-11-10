variable "bootstrap" {
  description = "Run with management-account credentials and assume OrganizationAccountAccessRole, for the first apply or to recover from broken CI roles."
  type        = bool
  default     = false
}

variable "site_domain_name" {
  description = "Not committed, like personal_domain_name in the management stack: locally in secrets.auto.tfvars.json (gitignored), in CI from the MEMBER_TFVARS_LMAC_SH secret."
  type        = string
  sensitive   = true
}
