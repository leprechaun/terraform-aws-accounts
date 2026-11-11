variable "bootstrap" {
  description = "Run with management-account credentials and assume OrganizationAccountAccessRole, for the first apply or to recover from broken CI roles."
  type        = bool
  default     = false
}
