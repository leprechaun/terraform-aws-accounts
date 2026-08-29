variable "aws_region" {
  description = "AWS region for the provider. Organizations/IAM are global services, but the provider still requires a region."
  type        = string
  default     = "us-east-1"
}

variable "owner_account_id" {
  description = "AWS account ID of the existing account used as the Organizations management (payer) account."
  type        = string
}

variable "existing_account_email" {
  description = "Root email address of the existing sub-account. Only matters at import time (email is ignore_changes'd afterward) — real value lives in the gitignored emails.auto.tfvars, never committed. Default is a harmless placeholder, not empty — the provider validates email length (6-64 chars) at plan time regardless of ignore_changes, so \"\" would fail validation in CI where the real value is never present."
  type        = string
  default     = "unset@example.com"
  sensitive   = true
}

variable "existing_account_name" {
  description = "Account name as it currently appears in AWS Organizations for the existing sub-account. Verify after import; adjust if terraform plan shows an unexpected diff."
  type        = string
}

variable "snacker_tracker_account_email" {
  description = "Root email address for the new sub-account. Only matters at creation time (email is ignore_changes'd afterward) — real value lives in the gitignored emails.auto.tfvars, never committed. Default is a harmless placeholder, not empty — see existing_account_email for why."
  type        = string
  default     = "unset@example.com"
  sensitive   = true
}

variable "krapao_reviews_account_email" {
  description = "Root email address for the krapao-reviews sub-account. Only matters at creation time (email is ignore_changes'd afterward) — real value lives in the gitignored emails.auto.tfvars, never committed. Default is a harmless placeholder, not empty — see existing_account_email for why."
  type        = string
  default     = "unset@example.com"
  sensitive   = true
}

variable "close_on_deletion" {
  description = "If true, destroying the new account resource in Terraform closes the AWS account instead of just removing it from the org. Keep false unless you mean it."
  type        = bool
  default     = false
}

variable "sso_username" {
  description = "IAM Identity Center username to grant AdministratorAccess to on every account (identity_center.tf). The user itself is created by hand in the console, not by Terraform — see README — so this must match whatever username you set there exactly, or the aws_identitystore_user lookup fails."
  type        = string
}

variable "personal_domain_name" {
  description = "Domain name for the shared apex hosted zone (dns.tf). Deliberately not in terraform.tfvars — supplied via the PERSONAL_DOMAIN_NAME GitHub Actions secret in CI (TF_VAR_personal_domain_name, plan job only) and via emails.auto.tfvars locally. sensitive = true additionally keeps it out of plan/apply console output, on top of it being a real GitHub secret now rather than just a redacted-output value."
  type        = string
  sensitive   = true
}
