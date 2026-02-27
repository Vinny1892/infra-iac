include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../atoms/aws/ec2"
}

# Override provider: needs both AWS and Cloudflare
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= v1.9.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.41.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      managed_by  = "terraform"
      environment = "testing"
      account     = "personal"
    }
  }
}

provider "cloudflare" {}
EOF
}

generate "cloudflare" {
  path      = "cloudflare.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "cloudflare_zone_id" {
  default = ""
}

variable "account_id" {
  default = ""
}

module "tunnel" {
  source      = "../../../../../../atoms/cloudflare/tunnel"
  zone_id     = var.cloudflare_zone_id
  domain      = "teste2.vinny.dev.br"
  tunnel_name = "tunnel_teste"
  secret      = "AQIDBAUGBwgBAgMEBQYHCAECAwQFBgcIAQIDBAUGBwg="
  account_id  = var.account_id
}

module "dns_record" {
  source = "../../../../../../atoms/cloudflare/domain"
  dns = {
    name    = "database.vinny.dev.br"
    content = aws_instance.ec2_instance.public_ip
    type    = "A"
  }
  cloudflare_zone_id = var.cloudflare_zone_id
  proxiable          = true
}

output "tunnel" {
  value = nonsensitive(module.tunnel.tunnel)
}
EOF
}

dependency "vpc" {
  config_path = "../../../network/vpc"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    subnet_public     = [{ id = "subnet-mock" }]
    security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  ami_id             = "ami-0281b255889b71ea7"
  instance_type      = "t2.micro"
  instance_name      = "postgres"
  subnet_id          = dependency.vpc.outputs.subnet_public[0].id
  security_group_ids = [dependency.vpc.outputs.security_group_id]
}
