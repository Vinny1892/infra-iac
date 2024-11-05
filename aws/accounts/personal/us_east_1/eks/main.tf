data "aws_security_group" "selected" {
  filter {
    name   = "tag:Name"
    values = ["securitygroupzinho"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
  filter {
    name   = "tag:type_subnet"
    values = ["public"]
  }
}
data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["MainVPC"]
  }
}

module "eks_cluster" {
  source = "../../../../modules/eks"

  region               = "us-east-1"
  cluster_name         = "my-eks-cluster"
  cluster_version      = "1.30"
  subnet_ids           =  data.aws_subnets.selected.ids
  public_subnet_id     = data.aws_subnets.public.ids[0]
  worker_instance_type = "t3.medium"
  desired_capacity     = 2
  max_capacity         = 3
  min_capacity         = 1
}