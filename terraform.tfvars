aws_region = "us-east-1"

owner_account_id = "307985306317"

existing_account_name = "lmacguire-sub-01"

# *_account_email vars are intentionally not set here — see
# emails.auto.tfvars (gitignored, not committed) and README.

close_on_deletion = false

sso_username = "lmac"

# personal_domain_name is intentionally not set here — see the
# PERSONAL_DOMAIN_NAME GitHub Actions secret and README. Locally, add it to
# emails.auto.tfvars (already gitignored) instead.
