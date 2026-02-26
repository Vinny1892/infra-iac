include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

dependency "vpc" {
  config_path = "../network/vpc"

  mock_outputs = {
    vpc_id = "vpc-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id = dependency.vpc.outputs.vpc_id
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "vpc_id" {
  description = "VPC ID from dependency"
  type        = string
}

module "internal_domain" {
  source   = "../../../../../modules/aws/cloud_map/create_internal_dns"
  vpc_id   = var.vpc_id
  dns_name = "regulus.internal"
}

output "namespace_id" {
  value = module.internal_domain.namespace_id
}

output "namespace_name" {
  value = module.internal_domain.namespace_name
}

output "route53_zone_id" {
  value = module.internal_domain.route53_zone_id
}
EOF
}
