# The app's zone, which predates this stack. Records stay with the app's
# repo; only the zone lives here. Whatever created it must stop managing it
# (terraform state rm in that repo) and look it up instead.
resource "aws_route53_zone" "khanom_xyz" {
  name = "khanom.xyz"

  lifecycle {
    # Recreating it changes its name servers and breaks the registrar's NS.
    prevent_destroy = true
  }
}

import {
  to = aws_route53_zone.khanom_xyz
  id = "Z0781732PCOBWRVFR9YS"
}
