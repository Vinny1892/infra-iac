data "oci_core_vcns" "main" {
  compartment_id = var.compartment_id

  filter {
    name   = "display_name"
    values = ["MainVCN"]
  }
}

data "oci_core_subnets" "public" {
  compartment_id = var.compartment_id
  vcn_id         = data.oci_core_vcns.main.virtual_networks[0].id

  filter {
    name   = "display_name"
    values = ["PublicSubnet-1"]
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}
