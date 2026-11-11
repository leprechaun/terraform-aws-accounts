module "baseline" {
  source = "../../modules/member-baseline"

  name = "lmac-sh"
}

# The alias was set before the baseline managed it.
import {
  to = module.baseline.aws_iam_account_alias.this
  id = "lmac-sh"
}
