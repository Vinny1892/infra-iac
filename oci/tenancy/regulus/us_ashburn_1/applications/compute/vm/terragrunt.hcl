include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

dependency "vcn" {
  config_path = "../../../network/vcn"

  mock_outputs = {
    subnet_public = [{ id = "ocid1.subnet.mock", availability_domain = "vSbr:US-ASHBURN-AD-1" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../atoms/oci/compute/instance"
}

inputs = {
  compartment_id      = get_env("OCI_COMPARTMENT_ID")
  availability_domain = dependency.vcn.outputs.subnet_public[0].availability_domain
  subnet_id           = dependency.vcn.outputs.subnet_public[0].id
  instance_name       = "vm-regulus"
  shape               = "VM.Standard.A1.Flex"
  ocpus               = 1
  memory_in_gbs       = 6
  image_id            = get_env("OCI_IMAGE_ID")
}
