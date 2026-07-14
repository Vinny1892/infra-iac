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

provider "cloudflare" {}
EOF
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "zone_id"  { type = string }
variable "vm_ip"    { type = string }

# Wildcard DNS — all *.vinny.dev.br subdomains resolve to the K3s VM IP.
# Traefik on K3s handles routing by Host header.
# external-dns can create specific records that override this wildcard.
resource "cloudflare_record" "k3s_wildcard" {
  zone_id         = var.zone_id
  name            = "*"
  content         = var.vm_ip
  type            = "A"
  ttl             = 120
  proxied         = false
  allow_overwrite = true
}

output "k3s_ip" {
  value = var.vm_ip
}
EOF
}

inputs = {
  zone_id = "1e9c3dce628d58fa69c21d0f67480d58"
  vm_ip   = dependency.vm.outputs.instance_public_ip
}
