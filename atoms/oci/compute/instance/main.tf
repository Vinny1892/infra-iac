locals {
  effective_primary_subnet_id = var.primary_subnet_id != "" ? var.primary_subnet_id : var.subnet_id
  use_reserved_public_ip      = var.reserved_public_ip_id != ""

  # O agent_config so e emitido se houver plugin pedido: um bloco vazio faria a
  # OCI desabilitar os plugins ligados por padrao na imagem.
  enabled_agent_plugins = compact([
    var.enable_run_command_plugin ? "Compute Instance Run Command" : "",
    var.enable_bastion_plugin ? "Bastion" : "",
  ])
  # user_data minimo para instancias que so precisam do sshd fora da 22. Quem
  # passa user_data_base64 monta o proprio bootstrap e ignora este bloco.
  generated_user_data = var.ssh_port != 22 ? base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    PORT=${var.ssh_port}

    # Drop-in, nao sed no sshd_config: o arquivo principal do Ubuntu abre com
    # Include /etc/ssh/sshd_config.d/*.conf e o cloud-image ja escreve ali.
    install -d -m 755 /etc/ssh/sshd_config.d
    printf 'Port %s\n' "$PORT" > /etc/ssh/sshd_config.d/99-port.conf

    # Ubuntu 24.04 usa socket activation no sshd. Com ssh.socket habilitado a
    # porta vem do ListenStream da unit e a diretiva Port e ignorada — sem este
    # override o sshd continuaria na 22 e a instancia ficaria inacessivel.
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      install -d -m 755 /etc/systemd/system/ssh.socket.d
      printf '%s\n' "[Socket]" "ListenStream=" "ListenStream=$PORT" \
        > /etc/systemd/system/ssh.socket.d/override.conf
      systemctl daemon-reload
      systemctl restart ssh.socket
    else
      sshd -t
      systemctl restart ssh
    fi

    # A imagem Ubuntu da OCI fecha a chain INPUT com REJECT e nao traz ufw.
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    apt-get install -y iptables-persistent -q
    netfilter-persistent save
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
    for_each = length(local.enabled_agent_plugins) > 0 ? [1] : []

    content {
      dynamic "plugins_config" {
        for_each = local.enabled_agent_plugins

        content {
          desired_state = "ENABLED"
          name          = plugins_config.value
        }
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
