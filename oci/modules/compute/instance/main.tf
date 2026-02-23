resource "oci_core_instance" "instance" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name        = var.instance_name
  shape               = var.shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type = "image"
    source_id   = var.image_id
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
    display_name     = "${var.instance_name}-vnic"
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }

  freeform_tags = {
    Name = var.instance_name
  }
}
