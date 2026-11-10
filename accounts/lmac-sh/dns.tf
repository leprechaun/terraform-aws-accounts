# The site's domain is registered elsewhere, so its name servers get set at
# that registrar by hand from the site_name_servers output. Records are the
# site repo's job; only the zone lives here.
resource "aws_route53_zone" "site" {
  name = var.site_domain_name

  lifecycle {
    # Recreating it changes its name servers and breaks the registrar's NS.
    prevent_destroy = true
  }
}
