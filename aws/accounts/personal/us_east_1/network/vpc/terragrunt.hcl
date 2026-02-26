include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
module "vpc" {
  source                     = "../../../../../../modules/aws/network/vpc"
  vpc_cidr_block             = "10.10.0.0/16"
  public_subnet_cidr_blocks  = ["10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidr_blocks = ["10.10.3.0/24", "10.10.4.0/24"]
  availability_zone          = ["us-east-1a", "us-east-1b"]
  region                     = "us-east-1"
}

module "security_group" {
  source = "../../../../../../modules/aws/network/security_group"
  vpc_id = module.vpc.vpc_id
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "subnet_private" {
  value = module.vpc.subnet_private
}

output "subnet_public" {
  value = module.vpc.subnet_public
}

output "security_group_id" {
  value = module.security_group.security_group_id
}

output "nat_gateway_private_ip" {
  value = module.vpc.nat_gateway_private_ip
}

output "nat_gateway_public_ip" {
  value = module.vpc.nat_gateway_public_ip
}
EOF
}
