
resource "cloudflare_record" "record" {
  zone_id = var.cloudflare_zone_id
  name    = var.dns.name
  content = var.dns.content
  type    = var.dns.type
  ttl     = var.proxiable ? 1 : 3600
  proxied = var.proxiable
}