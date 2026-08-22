provider "aws" {
  region = var.aws_region

  # No `profile` argument on purpose: locally, export AWS_PROFILE=lmac
  # before running terraform (same requirement the S3 backend already has).
  # In CI, credentials come from the OIDC-assumed role's env vars instead.
  # Either way the standard AWS credential chain picks it up automatically.

  # Organizations, account management, etc. must always run against the
  # management (owner) account. This hard-fails instead of silently running
  # against the wrong account if credentials resolve somewhere unexpected.
  allowed_account_ids = [var.owner_account_id]
}
