include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

terraform {
  source = "../../../../../../molecules/aws/network"
}

inputs = {
  vpc_cidr_block             = "10.10.0.0/16"
  public_subnet_cidr_blocks  = ["10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidr_blocks = ["10.10.3.0/24", "10.10.4.0/24"]
  availability_zone          = ["us-east-1a", "us-east-1b"]
  region                     = "us-east-1"
}
