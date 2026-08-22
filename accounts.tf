# Existing sub-account, already a member of the org — must be imported, not
# created. See README for the import command.
resource "aws_organizations_account" "lmacguire-sub-01" {
  name  = var.existing_account_name
  email = var.existing_account_email

  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    # role_name and iam_user_access_to_billing are create-time-only params
    # that the Organizations API never returns on read, so a plain import
    # always shows a phantom diff on them. email only matters at the moment
    # of import — its real value lives in the gitignored emails.auto.tfvars,
    # never committed, so most plans (CI included) see the placeholder
    # default instead. ignore_changes stops that placeholder from ever
    # being diffed against the real value already in state.
    ignore_changes = [role_name, iam_user_access_to_billing, email]

    # This account has live resources in it. Never let a stray
    # `terraform destroy` remove it from the org or close it.
    prevent_destroy = true
  }

  tags = {
    ManagedBy = "terraform"
  }

  depends_on = [aws_organizations_organization.this]
}

# New sub-account, created by Terraform.
resource "aws_organizations_account" "snacker-tracker" {
  name  = "snacker-tracker"
  email = var.snacker_tracker_account_email

  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = var.close_on_deletion

  lifecycle {
    # email only matters at the moment of creation — its real value lives
    # in the gitignored emails.auto.tfvars, never committed, so most plans
    # (CI included) see the placeholder default instead. ignore_changes
    # stops that placeholder from ever being diffed against the real value
    # already in state.
    ignore_changes = [email]
  }

  tags = {
    ManagedBy = "terraform"
  }

  depends_on = [aws_organizations_organization.this]
}

# New sub-account, created by Terraform.
resource "aws_organizations_account" "krapao-reviews" {
  name  = "krapao-reviews"
  email = var.krapao_reviews_account_email

  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = var.close_on_deletion

  lifecycle {
    # email only matters at the moment of creation — its real value lives
    # in the gitignored emails.auto.tfvars, never committed, so most plans
    # (CI included) see the placeholder default instead. ignore_changes
    # stops that placeholder from ever being diffed against the real value
    # already in state.
    ignore_changes = [email]
  }

  tags = {
    ManagedBy = "terraform"
  }

  depends_on = [aws_organizations_organization.this]
}
