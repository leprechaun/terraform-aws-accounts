module "baseline" {
  source = "../../modules/member-baseline"

  name = "lmac-sh"

  # site_roles.tf.
  github_roles = local.site_github_roles
}

# The alias was set before the baseline managed it.
import {
  to = module.baseline.aws_iam_account_alias.this
  id = "lmac-sh"
}
