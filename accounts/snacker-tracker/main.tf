module "baseline" {
  source = "../../modules/member-baseline"

  name = "snacker-tracker"
}

# The account's GitHub OIDC provider predates this stack. Roles in the
# account that trust it keep working; whatever created it must stop managing
# it (terraform state rm in that repo).
import {
  to = module.baseline.aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::132218943709:oidc-provider/token.actions.githubusercontent.com"
}
