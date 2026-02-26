include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

dependency "vcn" {
  config_path = "../../../network/vcn"

  mock_outputs = {
    vcn_id        = "ocid1.vcn.mock"
    subnet_public = [{ id = "ocid1.subnet.mock" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "compartment_id" {
  description = "OCID do compartment"
  type        = string
}

variable "image_id" {
  description = "OCID da imagem (Oracle Linux, Ubuntu, etc.)"
  type        = string
}

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

module "vm" {
  source = "../../../../../../../modules/oci/compute/instance"

  compartment_id      = var.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  subnet_id           = data.oci_core_subnets.public.subnets[0].id
  instance_name       = "vm-regulus"
  shape               = "VM.Standard.A1.Flex"
  ocpus               = 1
  memory_in_gbs       = 6
  image_id            = var.image_id
}

output "instance_id" {
  value = module.vm.instance_id
}

output "instance_public_ip" {
  value = module.vm.instance_public_ip
}

output "instance_private_ip" {
  value = module.vm.instance_private_ip
}
EOF
}
