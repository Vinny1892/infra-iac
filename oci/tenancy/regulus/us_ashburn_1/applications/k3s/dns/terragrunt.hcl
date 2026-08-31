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

output "k3s_ip" {
  value = var.vm_ip
}
EOF
}

inputs = {
  zone_id              = "1e9c3dce628d58fa69c21d0f67480d58"
  vm_ip                = dependency.vm.outputs.instance_public_ip
  cloudflare_api_token = run_cmd("--terragrunt-quiet", "op", "read", "op://Lab-IAC/Cloudflare API Token/credential")
}
