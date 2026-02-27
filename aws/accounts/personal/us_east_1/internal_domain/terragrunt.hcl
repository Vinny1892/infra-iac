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

terraform {
  source = "../../../../../atoms/aws/cloud_map/create_internal_dns"
}

inputs = {
  vpc_id   = dependency.vpc.outputs.vpc_id
  dns_name = "regulus.internal"
}
