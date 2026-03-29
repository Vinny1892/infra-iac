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
    source    = var.ssh_allowed_cidr
    protocol  = "6" # TCP
    stateless = false

    tcp_options {
      min = var.ssh_port
      max = var.ssh_port
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.additional_ingress_rules

    content {
      source      = ingress_security_rules.value.source
      protocol    = ingress_security_rules.value.protocol
      description = try(ingress_security_rules.value.description, null)
      stateless   = try(ingress_security_rules.value.stateless, false)

      dynamic "tcp_options" {
        for_each = try(ingress_security_rules.value.tcp_options, null) != null ? [ingress_security_rules.value.tcp_options] : []

        content {
          min = tcp_options.value.min
          max = tcp_options.value.max
        }
      }

      dynamic "udp_options" {
        for_each = try(ingress_security_rules.value.udp_options, null) != null ? [ingress_security_rules.value.udp_options] : []

        content {
          min = udp_options.value.min
          max = udp_options.value.max
        }
      }

      dynamic "icmp_options" {
        for_each = try(ingress_security_rules.value.icmp_options, null) != null ? [ingress_security_rules.value.icmp_options] : []

        content {
          type = icmp_options.value.type
          code = try(icmp_options.value.code, null)
        }
      }
    }
  }

  dynamic "egress_security_rules" {
    for_each = var.additional_egress_rules

    content {
      destination = egress_security_rules.value.destination
      protocol    = egress_security_rules.value.protocol
      description = try(egress_security_rules.value.description, null)
      stateless   = try(egress_security_rules.value.stateless, false)

      dynamic "tcp_options" {
        for_each = try(egress_security_rules.value.tcp_options, null) != null ? [egress_security_rules.value.tcp_options] : []

        content {
          min = tcp_options.value.min
          max = tcp_options.value.max
        }
      }

      dynamic "udp_options" {
        for_each = try(egress_security_rules.value.udp_options, null) != null ? [egress_security_rules.value.udp_options] : []

        content {
          min = udp_options.value.min
          max = udp_options.value.max
        }
      }

      dynamic "icmp_options" {
        for_each = try(egress_security_rules.value.icmp_options, null) != null ? [egress_security_rules.value.icmp_options] : []

        content {
          type = icmp_options.value.type
          code = try(icmp_options.value.code, null)
        }
      }
    }
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
