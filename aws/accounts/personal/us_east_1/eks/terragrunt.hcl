include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

dependency "vpc" {
  config_path = "../network/vpc"

  mock_outputs = {
    subnet_public  = [{ id = "subnet-mock" }]
    subnet_private = [{ id = "subnet-mock" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../atoms/aws/eks"
}

inputs = {
  max_pods_per_node    = 140
  region               = "us-east-1"
  cluster_name         = "my-eks-cluster"
  cluster_version      = "1.30"
  subnet_ids           = [for s in concat(dependency.vpc.outputs.subnet_private, dependency.vpc.outputs.subnet_public) : s.id]
  public_subnet_id     = dependency.vpc.outputs.subnet_public[0].id
  worker_instance_type = "t3.medium"
  desired_capacity     = 2
  max_capacity         = 2
  min_capacity         = 1
}
