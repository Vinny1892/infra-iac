output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "subnet_private" {
  value = aws_subnet.private.cidr_block
}

output "subnet_public" {
  value = aws_subnet.public.cidr_block
}

output "nat_gateway_private_ip" {
  value = aws_nat_gateway.nat_gateway.private_ip
}

output "nat_gateway_public_ip" {
  value = aws_nat_gateway.nat_gateway.public_ip
}