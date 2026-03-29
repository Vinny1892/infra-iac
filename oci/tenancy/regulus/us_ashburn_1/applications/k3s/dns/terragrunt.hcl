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

# A record: k3s.vinny.dev.br -> VM IP (used by whoami ingress)
resource "cloudflare_record" "k3s" {
  zone_id = var.zone_id
  name    = "k3s"
  content = var.vm_ip
  type    = "A"
  ttl     = 3600
  proxied = false
}

# A record: argocd-k3s.vinny.dev.br -> VM IP
resource "cloudflare_record" "argocd_k3s" {
  zone_id = var.zone_id
  name    = "argocd-k3s"
  content = var.vm_ip
  type    = "A"
  ttl     = 3600
  proxied = false
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
