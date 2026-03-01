resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr_block]
  display_name   = var.vcn_name
  dns_label      = "mainvcn"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "InternetGateway"
  enabled        = true
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "NATGateway"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "PublicRouteTable"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "PrivateRouteTable"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat.id
  }
}

resource "oci_core_security_list" "default" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "DefaultSecurityList"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "all"
    stateless = false
  }
}

resource "oci_core_subnet" "public" {
  count = length(var.public_subnet_cidr_blocks)

  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.public_subnet_cidr_blocks[count.index]
  display_name               = "PublicSubnet-${count.index + 1}"
  availability_domain        = var.availability_domains[count.index % length(var.availability_domains)]
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.default.id]
  prohibit_public_ip_on_vnic = false
  dns_label                  = "pub${count.index + 1}"
}

resource "oci_core_subnet" "private" {
  count = length(var.private_subnet_cidr_blocks)

  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.private_subnet_cidr_blocks[count.index]
  display_name               = "PrivateSubnet-${count.index + 1}"
  availability_domain        = var.availability_domains[count.index % length(var.availability_domains)]
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.default.id]
  prohibit_public_ip_on_vnic = true
  dns_label                  = "priv${count.index + 1}"
}
