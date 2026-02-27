include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

terraform {
  source = "../../../../../atoms/aws/ecs/cluster"
}

inputs = {
  cluster_name = "seila_cluster"
}
