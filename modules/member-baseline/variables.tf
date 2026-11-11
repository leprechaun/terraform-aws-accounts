variable "name" {
  description = "The account's name, which is also its directory under accounts/ and its state key."
  type        = string
}

variable "terraform_repo_subject" {
  description = "Sub claim prefix for terraform-aws-accounts itself, in the immutable form its tokens carry (see github_oidc.tf)."
  type        = string
  default     = "repo:leprechaun@355637/terraform-aws-accounts@1343063405"
}

variable "state_bucket" {
  type    = string
  default = "lmacguire-terraform"
}

variable "managed_policies" {
  description = "Customer managed policies to create in the account, keyed by name. Roles reference them by name, as an attachment or as their permissions boundary."
  type = map(object({
    policy = string
    # Changing it replaces the policy, so match what's live when importing.
    description = optional(string)
  }))
  default = {}
}

variable "github_roles" {
  description = <<-EOT
    GitHub Actions roles for workload repos, keyed by a short name (the role
    is named github-<key>). `subjects` are sub claim suffixes appended to
    repo:<repo>:, e.g. "environment:prod" or "ref:refs/heads/master". Use the
    immutable repo form (owner@id/repo@id) if the repo has
    use_immutable_subject turned on.
  EOT
  type = map(object({
    repo                 = string
    subjects             = list(string)
    policy_arns          = optional(list(string), [])
    managed_policies     = optional(list(string), [])
    inline_policies      = optional(map(string), {})
    permissions_boundary = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for role in values(var.github_roles) : alltrue([
        for name in concat(role.managed_policies, compact([role.permissions_boundary])) : contains(keys(var.managed_policies), name)
      ])
    ])
    error_message = "github_roles can only reference managed_policies by a name defined in var.managed_policies."
  }
}
