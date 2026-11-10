variable "account_id" {
  description = "Set in terraform.tfvars.json, which .github/workflows/member-accounts.yml also reads to find the account's roles."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12-digit ID from the management stack's lmac_sh_account_id output."
  }
}

variable "site_domain_name" {
  description = "Not committed, like personal_domain_name in the management stack: locally in secrets.auto.tfvars.json (gitignored), in CI from the MEMBER_TFVARS_LMAC_SH secret."
  type        = string
  sensitive   = true
}
