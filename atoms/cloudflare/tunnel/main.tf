terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.41.0"
    }
  }
}


resource "cloudflare_zero_trust_tunnel_cloudflared" "tunnel" {
  account_id = var.account_id
  name       = var.tunnel_name
  secret     = var.secret
}


# resource "cloudflare_zero_trust_tunnel_cloudflared_route" "route" {
#   account_id = var.account_id
#   network = "10.10.0.0/16"
#   tunnel_id = cloudflare_zero_trust_tunnel_cloudflared.tunnel.id
# }

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "config" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.tunnel.id

  config {
    ingress_rule {
      hostname = var.domain
      service  = "http://10.121.0.20:8989"
    }

    # Rota de fallback, caso a primeira não seja correspondida
    ingress_rule {
      service = "http_status:404"
    }
  }

}


resource "cloudflare_record" "record" {
  zone_id = var.zone_id
  name    = var.domain # Nome do subdomínio
  content = cloudflare_zero_trust_tunnel_cloudflared.tunnel.cname
  type    = "CNAME"
  proxied = true
}

output "tunnel" {
  value       = nonsensitive(cloudflare_zero_trust_tunnel_cloudflared.tunnel.tunnel_token)
  description = "teste"
}
