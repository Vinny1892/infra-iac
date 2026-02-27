output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "subnet_private" {
  value = module.vpc.subnet_private
}

output "subnet_public" {
  value = module.vpc.subnet_public
}

output "security_group_id" {
  value = module.security_group.security_group_id
}

output "nat_gateway_private_ip" {
  value = module.vpc.nat_gateway_private_ip
}

output "nat_gateway_public_ip" {
  value = module.vpc.nat_gateway_public_ip
}
