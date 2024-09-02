data "aws_ecs_cluster" "cluster" {
  cluster_name = "infratools_cluster"
}

data "aws_vpc" "vpc" {
  id="vpc-0c679f53639c92df2"
}

data "aws_service_discovery_dns_namespace" "internal_dns" {
  name = "principia-shared-services.internal"
  type = "DNS_PRIVATE"
}


data "aws_subnet" "selected" {
  id = "subnet-06dc6a37ecd9bd3c4"
}