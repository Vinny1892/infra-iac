variable "compartment_id" {
  description = "OCID do compartment"
  type        = string
}

variable "image_id" {
  description = "OCID da imagem (Oracle Linux, Ubuntu, etc.)"
  type        = string
}

module "vm" {
  source = "../../../../../../modules/compute/instance"

  compartment_id      = var.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  subnet_id           = data.oci_core_subnets.public.subnets[0].id
  instance_name       = "vm-regulus"
  shape               = "VM.Standard.A1.Flex"
  ocpus               = 1
  memory_in_gbs       = 6
  image_id            = var.image_id
}
