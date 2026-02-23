output "vcn_id" {
  value = module.vcn.vcn_id
}

output "vcn_cidr" {
  value = module.vcn.vcn_cidr
}

output "subnet_public" {
  value = module.vcn.subnet_public
}

output "subnet_private" {
  value = module.vcn.subnet_private
}

output "nat_gateway_id" {
  value = module.vcn.nat_gateway_id
}

output "internet_gateway_id" {
  value = module.vcn.internet_gateway_id
}
