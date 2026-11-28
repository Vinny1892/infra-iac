include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "vm" {
  config_path = "../../compute/vm"

  mock_outputs = {
    instance_public_ip = "1.2.3.4"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= v1.9.2"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.41.0"
    }
  }
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
EOF
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "zone_id"  { type = string }
variable "vm_ip"    { type = string }
variable "cloudflare_account_id" { type = string }

# DNS records for HTTP(S) apps are managed by external-dns in K3s. Minecraft
# uses a direct TCP connection, so its record must stay DNS-only.
resource "cloudflare_record" "minecraft" {
  zone_id = var.zone_id
  name    = "minecraft"
  type    = "A"
  content = var.vm_ip
  proxied = false
  ttl     = 1
}

# TeamSpeak tambem usa conexoes diretas UDP/TCP, que o proxy HTTP da Cloudflare
# nao transporta no plano comum. Por isso o registro e DNS-only.
resource "cloudflare_record" "teamspeak" {
  zone_id = var.zone_id
  name    = "teamspeak"
  type    = "A"
  content = var.vm_ip
  proxied = false
  ttl     = 1
}

# O Kubernetes MCP é público somente através do proxy Cloudflare. O app não
# possui política de identidade humana: aceita exclusivamente o Service Token
# dedicado que será armazenado no 1Password e cadastrado no Rakazo.
resource "cloudflare_zero_trust_access_application" "kubernetes_mcp" {
  account_id                = var.cloudflare_account_id
  name                      = "Rakazo Kubernetes MCP"
  domain                    = "k8s-mcp.vinny.dev.br"
  type                      = "self_hosted"
  session_duration          = "24h"
  service_auth_401_redirect = true
  app_launcher_visible      = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_service_token" "rakazo_kubernetes_mcp" {
  account_id = var.cloudflare_account_id
  name       = "Rakazo Kubernetes MCP"
  duration   = "8760h"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_policy" "rakazo_kubernetes_mcp" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.kubernetes_mcp.id
  name           = "Rakazo service token only"
  precedence     = 1
  decision       = "non_identity"

  include {
    service_token = [cloudflare_zero_trust_access_service_token.rakazo_kubernetes_mcp.id]
  }
}

# A zona usa SSL Flexible globalmente. Este ruleset já existia no painel;
# importamo-lo para preservar sua regra legada e aplicar Full (strict) somente
# ao hostname do Kubernetes MCP.
resource "cloudflare_ruleset" "http_config_settings" {
  zone_id     = var.zone_id
  name        = "default"
  description = ""
  kind        = "zone"
  phase       = "http_config_settings"

  rules {
    action      = "set_config"
    description = "ssl rule rewrite"
    enabled     = false
    expression  = "(http.host eq \"seila.vinny.dev.br\")"
    ref         = "fce8ae6674dd4a38b318d0798b9deae1"

    action_parameters {
      ssl = "full"
    }
  }

  rules {
    action      = "set_config"
    description = "Kubernetes MCP origin TLS"
    enabled     = true
    expression  = "(http.host eq \"k8s-mcp.vinny.dev.br\")"
    ref         = "kubernetes-mcp-full-strict"

    action_parameters {
      ssl = "strict"
    }
  }
}

output "kubernetes_mcp_access_client_id" {
  value     = cloudflare_zero_trust_access_service_token.rakazo_kubernetes_mcp.client_id
  sensitive = true
}

output "kubernetes_mcp_access_client_secret" {
  value     = cloudflare_zero_trust_access_service_token.rakazo_kubernetes_mcp.client_secret
  sensitive = true
}

output "k3s_ip" {
  value = var.vm_ip
}
EOF
}

inputs = {
  zone_id               = "1e9c3dce628d58fa69c21d0f67480d58"
  cloudflare_account_id = "cde8e50a06dd73be33b9bfd8d7e16860"
  vm_ip                 = dependency.vm.outputs.instance_public_ip
  cloudflare_api_token  = run_cmd("--terragrunt-quiet", "op", "read", "op://Lab-IAC/Cloudflare API Token/credential")
}
