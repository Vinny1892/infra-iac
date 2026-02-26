output "vcn_id" {
  value = oci_core_vcn.main.id
}

output "vcn_cidr" {
  value = oci_core_vcn.main.cidr_blocks[0]
}

output "subnet_public" {
  value = oci_core_subnet.public
}

output "subnet_private" {
  value = oci_core_subnet.private
}

output "internet_gateway_id" {
  value = oci_core_internet_gateway.igw.id
}

output "nat_gateway_id" {
  value = oci_core_nat_gateway.nat.id
}

output "security_list_id" {
  value = oci_core_security_list.default.id
}
