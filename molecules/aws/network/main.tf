resource "aws_vpc" "main" {
  enable_dns_hostnames = true
  enable_dns_support   = true
  cidr_block           = var.vpc_cidr_block
  tags = {
    Name = "MainVPC"
  }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidr_blocks)

  cidr_block              = var.public_subnet_cidr_blocks[count.index]
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zone[count.index]
  map_public_ip_on_launch = true

  tags = merge({
    type_subnet = "public"
    Name        = "PublicSubnet-${count.index + 1}"
  }, var.extra_public_subnet_tags)
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidr_blocks)

  cidr_block        = var.private_subnet_cidr_blocks[count.index]
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zone[count.index]

  tags = merge({
    Name        = "PrivateSubnet-${count.index + 1}"
  }, var.extra_private_subnet_tags)
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "r" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "my-routing-table"
  }
}

resource "aws_route_table_association" "a" {
  count          = length(var.public_subnet_cidr_blocks)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.r.id
}

resource "aws_eip" "nat_gateway_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_gateway_eip.id
  subnet_id     = aws_subnet.public[0].id
}

resource "aws_route_table" "nat_gateway_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }

  tags = {
    Name = "Route Table for NAT Gateway"
  }
}

resource "aws_route_table_association" "nat_gateway_rt_assoc" {
  count          = length(var.private_subnet_cidr_blocks)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.nat_gateway_rt.id
}

resource "aws_security_group" "example" {
  description = "seila"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ingress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "securitygroupzinho"
  }
}
