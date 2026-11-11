module "baseline" {
  source = "../../modules/member-baseline"

  name = "snacker-tracker"

  # See boundaries.tf.
  managed_policies = {
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
  }

  github_roles = {
    # snacker-tracker/aws-infra's own CI roles, which it used to create
    # itself; names and ARNs are unchanged since its repo variables hold
    # them.

    # Used only by aws-infra's apply job, gated behind its "prod"
    # environment (manual approval), hence the environment subject rather
    # than a branch ref.
    actions-admin = {
      repo        = local.aws_infra_repo
      subjects    = ["environment:prod"]
      policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    }

    # Used by the unattended plan job on every push to any branch, for
    # pre-merge visibility. Deliberately can't mutate anything, so leaked
    # credentials from any branch can only read the account.
    actions-plan = {
      repo        = local.aws_infra_repo
      subjects    = ["ref:refs/heads/*"]
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      inline_policies = {
        state-lock = data.aws_iam_policy_document.aws_infra_plan_state_lock.json
      }
    }
  }
}

locals {
  # AWS only accepts OIDC trust policies scoped on sub or job_workflow_ref.
  # job_workflow_ref matching was tried first and STS rejected it with
  # "AccessDenied: An unknown error occurred" despite a byte-for-byte
  # correct policy, so it's sub, which this org's tokens carry in the
  # immutable form with numeric org and repo IDs.
  aws_infra_repo = "snacker-tracker@59108816/aws-infra@1342946994"
}

# ReadOnlyAccess excludes s3:PutObject/DeleteObject, but Terraform's S3
# lockfile has to be created and deleted even for a plan. Scoped to exactly
# the lock object, not the state itself.
data "aws_iam_policy_document" "aws_infra_plan_state_lock" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::snacker-tracker-aws-infra-tfstate/root/terraform.tfstate.tflock"]
  }
}

# The account's GitHub OIDC provider predates this stack. Roles in the
# account that trust it keep working; whatever created it must stop managing
# it (terraform state rm in that repo).
import {
  to = module.baseline.aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::132218943709:oidc-provider/token.actions.githubusercontent.com"
}

# aws-infra's CI roles, previously created by aws-infra itself (it now has
# removed blocks for them).
import {
  to = module.baseline.aws_iam_role.github["actions-admin"]
  id = "github-actions-admin"
}

import {
  to = module.baseline.aws_iam_role_policy_attachment.github["actions-admin/arn:aws:iam::aws:policy/AdministratorAccess"]
  id = "github-actions-admin/arn:aws:iam::aws:policy/AdministratorAccess"
}

import {
  to = module.baseline.aws_iam_role.github["actions-plan"]
  id = "github-actions-plan"
}

import {
  to = module.baseline.aws_iam_role_policy_attachment.github["actions-plan/arn:aws:iam::aws:policy/ReadOnlyAccess"]
  id = "github-actions-plan/arn:aws:iam::aws:policy/ReadOnlyAccess"
}

import {
  to = module.baseline.aws_iam_role_policy.github["actions-plan/state-lock"]
  id = "github-actions-plan:state-lock"
}
