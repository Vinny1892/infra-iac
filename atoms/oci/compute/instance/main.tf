locals {
  effective_primary_subnet_id = var.primary_subnet_id != "" ? var.primary_subnet_id : var.subnet_id
  use_reserved_public_ip      = var.reserved_public_ip_id != ""
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

  dynamic "agent_config" {
    for_each = var.enable_run_command_plugin ? [1] : []

    content {
      plugins_config {
        desired_state = "ENABLED"
        name          = "Compute Instance Run Command"
      }
    }
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = local.effective_primary_subnet_id
    assign_public_ip = local.use_reserved_public_ip ? false : var.assign_public_ip
    display_name     = "${var.instance_name}-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_authorized_keys != "" ? var.ssh_authorized_keys : file(var.ssh_public_key_path)
    user_data           = local.effective_user_data
  }

  freeform_tags = {
    Name = var.instance_name
  }

  # A OCI trata mudanças em ssh_authorized_keys como replacement da instância.
  # A chave configurada continua sendo usada em criações novas; rotações em nós
  # existentes devem atualizar authorized_keys dentro do sistema operacional.
  lifecycle {
    ignore_changes = [metadata["ssh_authorized_keys"]]
  }
}

resource "oci_core_volume" "data" {
  count = var.data_volume_size_in_gbs != null ? 1 : 0

  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = var.data_volume_display_name != "" ? var.data_volume_display_name : "${var.instance_name}-data"
  size_in_gbs         = var.data_volume_size_in_gbs
  vpus_per_gb         = var.data_volume_vpus_per_gb

  freeform_tags = {
    Name = var.data_volume_display_name != "" ? var.data_volume_display_name : "${var.instance_name}-data"
  }
}

resource "oci_core_volume_attachment" "data" {
  count = var.data_volume_size_in_gbs != null ? 1 : 0

  attachment_type = "paravirtualized"
  device          = var.data_volume_device
  display_name    = "${var.instance_name}-data-attachment"
  instance_id     = oci_core_instance.instance.id
  volume_id       = oci_core_volume.data[0].id
}

# Anexação do IP público reservado à VNIC primária.
#
# Não dá para usar o recurso oci_core_public_ip aqui: ele precisaria do
# private_ip_id (que só existe depois da instância) enquanto a instância precisa
# do ip_address dele no user_data — ciclo de dependência. O IP é criado numa unit
# separada (network/reserved_ip) e a associação é feita via CLI.
data "oci_core_vnic_attachments" "primary" {
  count          = local.use_reserved_public_ip ? 1 : 0
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.instance.id
}

data "oci_core_private_ips" "primary" {
  count   = local.use_reserved_public_ip ? 1 : 0
  vnic_id = data.oci_core_vnic_attachments.primary[0].vnic_attachments[0].vnic_id
}

resource "terraform_data" "attach_reserved_public_ip" {
  count = local.use_reserved_public_ip ? 1 : 0

  triggers_replace = [
    var.reserved_public_ip_id,
    data.oci_core_private_ips.primary[0].private_ips[0].id,
  ]

  provisioner "local-exec" {
    command = "oci network public-ip update --public-ip-id ${var.reserved_public_ip_id} --private-ip-id ${data.oci_core_private_ips.primary[0].private_ips[0].id} --force"
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
