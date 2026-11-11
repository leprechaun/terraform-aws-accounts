module "baseline" {
  source = "../../modules/member-baseline"

  name = "snacker-tracker"

  # Boundaries (boundaries.tf), then the app roles' policies (app_roles.tf).
  managed_policies = merge({
    app-role-permissions-boundary = {
      description = "Boundary applied to every per-app GitHub Actions role: blocks IAM self-escalation regardless of the role's own policy"
      policy      = data.aws_iam_policy_document.app_role_boundary.json
    }
    runtime-role-permissions-boundary = {
      description = "Boundary required on every app runtime role: no IAM, Organizations or account management, whatever the role's own policy says"
      policy      = data.aws_iam_policy_document.runtime_role_boundary.json
    }
    reporter-serverless-runtime-boundary = {
      description = "Boundary required on reporter-serverless's runtime roles: only that app's own bucket, stream, event bus, queues and log groups"
      policy      = data.aws_iam_policy_document.reporter_serverless_runtime_boundary.json
    }
  }, local.app_managed_policies)

  # The app deploy roles (app_roles.tf).
  github_roles = local.app_github_roles
}

# The account's GitHub OIDC provider predates this stack. Roles in the
# account that trust it keep working; whatever created it must stop managing
# it (terraform state rm in that repo).
import {
  to = module.baseline.aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::132218943709:oidc-provider/token.actions.githubusercontent.com"
}

# The account alias and S3 public access block predate this stack (they
# were snacker-tracker/aws-infra's); the alias is the baseline's default,
# the account name.
import {
  to = module.baseline.aws_iam_account_alias.this
  id = "snacker-tracker"
}

import {
  to = module.baseline.aws_s3_account_public_access_block.this
  id = local.account_id
}
