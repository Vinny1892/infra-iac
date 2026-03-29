locals {
  effective_primary_subnet_id = var.primary_subnet_id != "" ? var.primary_subnet_id : var.subnet_id
  generated_user_data = var.ssh_port != 22 ? base64encode(<<-EOF
    #!/bin/bash
    PORT=${var.ssh_port}
    if grep -q "^#*Port " /etc/ssh/sshd_config; then
      sed -i "s/^#*Port .*/Port $PORT/" /etc/ssh/sshd_config
    else
      echo "Port $PORT" >> /etc/ssh/sshd_config
    fi
    ufw allow $PORT/tcp 2>/dev/null || true
    systemctl restart sshd
  EOF
  ) : null
  effective_user_data = var.user_data_base64 != null ? var.user_data_base64 : local.generated_user_data
}

data "external" "marketplace_agreements" {
  count = var.marketplace_listing_id != "" ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_marketplace_agreements.sh"]

  query = {
    listing_id      = var.marketplace_listing_id
    listing_version = var.marketplace_listing_version
    compartment_id  = var.compartment_id
  }
}

resource "oci_core_app_catalog_subscription" "this" {
  count                    = var.marketplace_listing_id != "" ? 1 : 0
  compartment_id           = var.compartment_id
  listing_id               = var.marketplace_listing_id
  listing_resource_version = var.marketplace_listing_version
  eula_link                = data.external.marketplace_agreements[0].result.eula_link
  oracle_terms_of_use_link = data.external.marketplace_agreements[0].result.oracle_terms_of_use_link
  signature                = data.external.marketplace_agreements[0].result.signature
  time_retrieved           = data.external.marketplace_agreements[0].result.time_retrieved
}

resource "oci_core_instance" "instance" {
  depends_on          = [oci_core_app_catalog_subscription.this]
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
    subnet_id        = local.effective_primary_subnet_id
    assign_public_ip = var.assign_public_ip
    display_name     = "${var.instance_name}-vnic"
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
    user_data           = local.effective_user_data
  }

  freeform_tags = {
    Name = var.instance_name
  }
}

resource "oci_core_vnic_attachment" "secondary" {
  count = length(var.secondary_vnic_subnet_ids)

  instance_id = oci_core_instance.instance.id

  create_vnic_details {
    subnet_id        = var.secondary_vnic_subnet_ids[count.index]
    assign_public_ip = false
    display_name     = "${var.instance_name}-vnic-${count.index + 2}"
  }
}
