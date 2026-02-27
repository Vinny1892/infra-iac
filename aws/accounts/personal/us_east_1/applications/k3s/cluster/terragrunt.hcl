include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

terraform {
  source = "../../../../../../../organisms/aws/k3s/cluster"
}

generate "tls_provider" {
  path      = "tls_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
EOF
}

dependency "vpc" {
  config_path = "../../../network/vpc"

  mock_outputs = {
    vpc_id         = "vpc-mock"
    vpc_cidr       = "10.10.0.0/16"
    subnet_public  = [{ id = "subnet-mock-1" }, { id = "subnet-mock-2" }]
    subnet_private = [{ id = "subnet-mock-3" }, { id = "subnet-mock-4" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id             = dependency.vpc.outputs.vpc_id
  vpc_cidr           = dependency.vpc.outputs.vpc_cidr
  public_subnet_ids  = [for s in dependency.vpc.outputs.subnet_public : s.id]
  private_subnet_ids = [for s in dependency.vpc.outputs.subnet_private : s.id]
}
