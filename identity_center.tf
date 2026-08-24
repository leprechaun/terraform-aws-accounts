# IAM Identity Center permission set + account assignments. The instance
# itself was enabled by hand via the console (no Terraform resource creates
# it — see README), and turned out to already be homed in ap-southeast-1,
# so every resource/data source here targets that region explicitly via the
# aws.ap_southeast_1 provider alias (providers.tf), not the default us-east-1
# one — sso-admin/identitystore API calls have to go to the instance's home
# region.
#
# The user itself is intentionally NOT managed here — see README. It's
# created once by hand in the console (so the invite email + password/MFA
# enrollment actually happen, which Terraform has no resource for), and
# looked up below by username instead.

data "aws_ssoadmin_instances" "this" {
  provider = aws.ap_southeast_1
}

data "aws_identitystore_user" "me" {
  provider          = aws.ap_southeast_1
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.sso_username
    }
  }
}

resource "aws_ssoadmin_permission_set" "admin" {
  provider = aws.ap_southeast_1

  name             = "AdministratorAccess"
  instance_arn     = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin" {
  provider = aws.ap_southeast_1

  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# One assignment per account — management account plus all three members.
# Same AdministratorAccess permission set everywhere since this is a single-
# operator org; split into per-account permission sets later if that ever
# stops being true.
locals {
  sso_admin_accounts = {
    management       = var.owner_account_id
    lmacguire-sub-01 = aws_organizations_account.lmacguire-sub-01.id
    snacker-tracker  = aws_organizations_account.snacker-tracker.id
    krapao-reviews   = aws_organizations_account.krapao-reviews.id
  }
}

resource "aws_ssoadmin_account_assignment" "admin" {
  for_each = local.sso_admin_accounts
  provider = aws.ap_southeast_1

  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn

  principal_id   = data.aws_identitystore_user.me.user_id
  principal_type = "USER"

  target_id   = each.value
  target_type = "AWS_ACCOUNT"
}
