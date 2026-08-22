variable "aws_profile" {
  description = "AWS CLI profile used to authenticate against the owner (management) account."
  type        = string
  default     = "lmac"
}

variable "aws_region" {
  description = "AWS region for the provider. Organizations/IAM are global services, but the provider still requires a region."
  type        = string
  default     = "us-east-1"
}

variable "owner_account_id" {
  description = "AWS account ID of the existing account used as the Organizations management (payer) account."
  type        = string
}

variable "existing_account_id" {
  description = "AWS account ID of the existing sub-account being imported into this org."
  type        = string
}

variable "existing_account_email" {
  description = "Root email address of the existing sub-account. Must match AWS's record exactly (Organizations returns this on import, so it will show as a diff if wrong)."
  type        = string
}

variable "existing_account_name" {
  description = "Account name as it currently appears in AWS Organizations for the existing sub-account. Verify after import; adjust if terraform plan shows an unexpected diff."
  type        = string
}

variable "snacker_tracker_account_name" {
  description = "Name for the new sub-account Terraform will create."
  type        = string
}

variable "snacker_tracker_account_email" {
  description = "Root email address for the new sub-account. Must be unique across all AWS accounts (not just this org)."
  type        = string
}

variable "krapao_reviews_account_name" {
  description = "Name for the krapao-reviews sub-account Terraform will create."
  type        = string
}

variable "krapao_reviews_account_email" {
  description = "Root email address for the krapao-reviews sub-account. Must be unique across all AWS accounts (not just this org)."
  type        = string
}

variable "close_on_deletion" {
  description = "If true, destroying the new account resource in Terraform closes the AWS account instead of just removing it from the org. Keep false unless you mean it."
  type        = bool
  default     = false
}
