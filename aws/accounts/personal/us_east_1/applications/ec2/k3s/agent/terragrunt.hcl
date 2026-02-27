include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

dependency "vpc" {
  config_path = "../../../../network/vpc"

  mock_outputs = {
    subnet_public     = [{ id = "subnet-mock" }]
    security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../../atoms/aws/ec2"
}

inputs = {
  ami_id             = "ami-0182f373e66f89c85"
  instance_type      = "t2.micro"
  instance_name      = "agent-0"
  subnet_id          = dependency.vpc.outputs.subnet_public[0].id
  security_group_ids = [dependency.vpc.outputs.security_group_id]
}
