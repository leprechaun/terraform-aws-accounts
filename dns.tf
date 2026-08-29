# Shared apex zone(s) — same "created once, rarely touched, no single
# project owns it" category as CloudTrail/cost exports/Identity Center
# elsewhere in this repo. Project-specific subdomains get delegated out via
# NS records added here later, pointing at a zone created in that project's
# own account/state — this repo only ever holds the apex zone and those
# delegation records, never a project's own records or certs.

resource "aws_route53_zone" "personal_domain" {
  name = var.personal_domain_name

  lifecycle {
    # Live DNS — an accidental destroy breaks resolution for anything
    # pointed at this zone or delegated from it.
    prevent_destroy = true
  }
}
