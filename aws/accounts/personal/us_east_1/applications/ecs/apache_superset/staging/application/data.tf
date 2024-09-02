data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["MainVPC"]
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

data "aws_ecs_cluster" "cluster" {
  cluster_name = "seila_cluster"
}

data "aws_service_discovery_dns_namespace" "internal_dns" {
  name = "regulus.internal"
  type = "DNS_PRIVATE"
}


data "aws_security_group" "sg" {
  filter {
    name = "tag:Name"
    values = ["securitygroupzinho"]
  }
}
