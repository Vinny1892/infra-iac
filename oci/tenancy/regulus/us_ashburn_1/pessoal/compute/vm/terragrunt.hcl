include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))

  user_data = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/bootstrap.log) 2>&1
    set -euo pipefail

    echo "==> Pacotes base"
    apt-get update -y
    apt-get install -y ca-certificates curl wireguard-tools ufw

    echo "==> Docker (repositorio oficial)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker ubuntu

    echo "==> Encaminhamento de IP para a VPN"
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
    sysctl --system

    echo "==> iptables: as regras da security list nao bastam, a instancia tambem filtra"
    iptables -I INPUT -p udp --dport 51820 -j ACCEPT
    iptables -I INPUT -p tcp --dport 25565 -j ACCEPT
    iptables -I INPUT -p udp --dport 9987  -j ACCEPT
    iptables -I INPUT -p tcp --dport 30033 -j ACCEPT
    apt-get install -y iptables-persistent -q
    netfilter-persistent save

    echo "==> Pronto. Minecraft, TeamSpeak 6 e WireGuard ficam a cargo do provisionamento manual."
  EOF
  )
}

dependency "compartment" {
  config_path = "../../identity/compartment"

  mock_outputs = {
    compartment_id = "ocid1.compartment.mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "vcn" {
  config_path = "../../network/vcn"

  mock_outputs = {
    subnet_public = [{ id = "ocid1.subnet.mock", availability_domain = "jnRJ:US-ASHBURN-AD-1" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../atoms/oci/compute/instance"
}

inputs = {
  compartment_id      = dependency.compartment.outputs.compartment_id
  availability_domain = dependency.vcn.outputs.subnet_public[0].availability_domain
  subnet_id           = dependency.vcn.outputs.subnet_public[0].id
  instance_name       = "vm-pessoal"
  shape               = "VM.Standard.A1.Flex"

  # Metade da franquia Ampere (4 OCPU / 24 GB no total); a outra metade e do agrostack.
  # Sao 2 OCPU porque o Minecraft nao roda bem em um nucleo: a thread de tick e o GC
  # competem. 10 GB comportam heap de ~6 GB, sobrando para TeamSpeak e WireGuard.
  ocpus         = 2
  memory_in_gbs = 10

  # 80 dos 200 GB de block storage da franquia; os outros 120 sao do agrostack.
  boot_volume_size_in_gbs = 80

  image_id         = local.region_vars.locals.image_id
  user_data_base64 = local.user_data
}
