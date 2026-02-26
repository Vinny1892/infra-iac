include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "compartment_id" {
  description = "OCID do compartment"
  type        = string
}

module "vcn" {
  source = "../../../../../../modules/oci/network/vcn"

  compartment_id             = var.compartment_id
  vcn_cidr_block             = "10.20.0.0/16"
  public_subnet_cidr_blocks  = ["10.20.1.0/24", "10.20.2.0/24"]
  private_subnet_cidr_blocks = ["10.20.3.0/24", "10.20.4.0/24"]
  availability_domains       = ["vSbr:US-ASHBURN-AD-1", "vSbr:US-ASHBURN-AD-2"]
  vcn_name                   = "MainVCN"
}

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
EOF
}
