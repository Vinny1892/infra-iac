include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

terraform {
  source = "../../../../../../../atoms/aws/ec2"
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
  ami_id             = "ami-0f3caa1cf4417e51b"
  instance_type      = "t2.medium"
  instance_name      = "openclaw"
  subnet_id          = dependency.vpc.outputs.subnet_public[0].id
  security_group_ids = [dependency.vpc.outputs.security_group_id]
}
