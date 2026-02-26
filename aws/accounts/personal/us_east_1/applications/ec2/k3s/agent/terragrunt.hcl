include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

dependency "vpc" {
  config_path = "../../../../network/vpc"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    subnet_public     = [{ id = "subnet-mock" }]
    security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
data "aws_security_group" "selected" {
  filter {
    name   = "tag:Name"
    values = ["securitygroupzinho"]
  }
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
  filter {
    name   = "tag:type_subnet"
    values = ["public"]
  }
}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["MainVPC"]
  }
}

locals {
  ami_id        = "ami-0182f373e66f89c85"
  instance_name = "agent"
  instance_type = "t2.micro"
  domain_name   = "database.vinny.dev.br"
  type          = "A"
}

module "agent-k3s" {
  count              = 1
  source             = "../../../../../../../../modules/aws/ec2"
  instance_type      = local.instance_type
  ami_id             = local.ami_id
  instance_name      = "$${local.instance_name}-$${count.index}"
  subnet_id          = data.aws_subnets.selected.ids[0]
  security_group_ids = [data.aws_security_group.selected.id]
}
EOF
}
