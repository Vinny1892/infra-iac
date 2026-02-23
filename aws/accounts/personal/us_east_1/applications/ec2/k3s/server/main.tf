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

# data "aws_service_discovery_dns_namespace" "internal_dns" {
#   name = "regulus.internal"
#   type = "DNS_PRIVATE"
# }



locals {
  ami_id = "ami-0182f373e66f89c85"
  # ami_id = "ami-0281b255889b71ea7"
  instance_name = "server"
  instance_type = "t2.micro"
  domain_name = "database.vinny.dev.br"
  type = "A"
}


module "server-k3s" {
  count = 1
  source            = "../../../../../../../modules/ec2"
  instance_type     = local.instance_type
  ami_id = local.ami_id
  instance_name = "${local.instance_name}-${count.index}"
  subnet_id         = data.aws_subnets.selected.ids[0]
  security_group_ids = [data.aws_security_group.selected.id]
}