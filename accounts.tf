# Existing sub-account, already a member of the org — must be imported, not
# created. See README for the import command.
resource "aws_organizations_account" "existing" {
  name  = var.existing_account_name
  email = var.existing_account_email

  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    # role_name and iam_user_access_to_billing are create-time-only params
    # that the Organizations API never returns on read, so a plain import
    # always shows a phantom diff on them. Ignoring avoids Terraform trying
    # to force-replace (i.e. delete and recreate) a real, already-populated
    # account.
    ignore_changes = [role_name, iam_user_access_to_billing]

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
  name  = var.snacker_tracker_account_name
  email = var.snacker_tracker_account_email

  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = var.close_on_deletion

  tags = {
    ManagedBy = "terraform"
  }

  depends_on = [aws_organizations_organization.this]
}

# New sub-account, created by Terraform.
resource "aws_organizations_account" "krapao-reviews" {
  name  = var.krapao_reviews_account_name
  email = var.krapao_reviews_account_email

  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = var.close_on_deletion

  tags = {
    ManagedBy = "terraform"
  }

  depends_on = [aws_organizations_organization.this]
}
