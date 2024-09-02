
resource "cloudflare_record" "record" {
  zone_id = var.cloudflare_zone_id
  name    = var.dns.name
  value   =  var.dns.value
  type    =  "CNAME"
  ttl     = 3600
}