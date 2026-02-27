include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

terraform {
  source = "../../../../../../atoms/oci/network/vcn"
}

inputs = {
  compartment_id             = get_env("OCI_COMPARTMENT_ID")
  vcn_cidr_block             = "10.20.0.0/16"
  public_subnet_cidr_blocks  = ["10.20.1.0/24", "10.20.2.0/24"]
  private_subnet_cidr_blocks = ["10.20.3.0/24", "10.20.4.0/24"]
  availability_domains       = ["vSbr:US-ASHBURN-AD-1", "vSbr:US-ASHBURN-AD-2"]
  vcn_name                   = "MainVCN"
}
