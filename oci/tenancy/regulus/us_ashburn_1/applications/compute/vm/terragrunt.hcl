include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars  = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))
  k3s_dns_name = "k3s.vinny.dev.br"
  k3s_version  = "v1.36.4+k3s1"
}

dependency "vcn" {
  config_path = "../../../network/vcn"

  mock_outputs = {
    subnet_public = [{ id = "ocid1.subnet.mock", availability_domain = "jnRJ:US-ASHBURN-AD-1" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "reserved_ip" {
  config_path = "../../../network/reserved_ip"

  mock_outputs = {
    public_ip_id      = "ocid1.publicip.mock"
    public_ip_address = "203.0.113.10"
  }
  # destroy/output/init tambem precisam dos mocks: enquanto a unit reserved_ip
  # nao tiver state, a falha em resolver estes outputs derruba o parse de TODO
  # o bloco dependency — inclusive o da vcn — e impede destruir a VM.
  # Os mocks so entram quando nao ha outputs reais; com a unit aplicada, o valor
  # verdadeiro prevalece.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "output", "destroy"]
}

terraform {
  source = "../../../../../../../atoms/oci/compute/instance"
}

# O user_data fica em inputs (e nao em locals) porque precisa do endereco vindo
# de dependency.reserved_ip, e locals do Terragrunt sao avaliados antes das
# dependencies.
inputs = {
  compartment_id      = local.region_vars.locals.compartment_id
  availability_domain = dependency.vcn.outputs.subnet_public[0].availability_domain
  subnet_id           = dependency.vcn.outputs.subnet_public[0].id
  instance_name       = "vm-regulus"
  shape               = "VM.Standard.A1.Flex"
  ocpus               = 4
  memory_in_gbs       = 24
  image_id            = local.region_vars.locals.image_id
  ssh_authorized_keys = run_cmd("--terragrunt-quiet", "op", "read", "op://Personal/Pessoal/public key")

  # Volume dedicado ao Longhorn. Boot (47 GB) + dados (100 GB) permanecem
  # abaixo dos 200 GB combinados da franquia Always Free desta tenancy.
  data_volume_size_in_gbs   = 100
  data_volume_display_name  = "vm-regulus-longhorn"
  data_volume_vpus_per_gb   = 10
  data_volume_device        = "/dev/oracleoci/oraclevdb"
  enable_run_command_plugin = true

  reserved_public_ip_id      = dependency.reserved_ip.outputs.public_ip_id
  reserved_public_ip_address = dependency.reserved_ip.outputs.public_ip_address

  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/k3s-install.log) 2>&1
    set -euo pipefail

    K3S_VERSION="${local.k3s_version}"
    DNS_NAME="${local.k3s_dns_name}"
    PUBLIC_IP="${dependency.reserved_ip.outputs.public_ip_address}"

    echo "==> IP publico reservado, injetado pelo Terraform: $PUBLIC_IP"

    # O IP reservado e anexado a VNIC logo apos a criacao da instancia, o que
    # pode ocorrer depois do cloud-init comecar. Sem esperar a rota de saida,
    # o primeiro download falha e o set -e derruba o script inteiro.
    echo "==> Aguardando conectividade de saida"
    for i in $(seq 1 90); do
      if curl -sf -m 5 -o /dev/null https://get.k3s.io; then
        echo "  rede pronta na tentativa $i"
        break
      fi
      echo "  tentativa $i/90 — sem rota de saida ainda, aguardando 5s..."
      sleep 5
    done
    curl -sf -m 10 -o /dev/null https://get.k3s.io || {
      echo "ERRO: sem conectividade de saida apos 90 tentativas"
      exit 1
    }

    echo "==> Instalando pre-requisitos Longhorn"
    apt-get update -y
    apt-get install -y open-iscsi nfs-common
    systemctl enable --now iscsid

    echo "==> Abrindo portas no iptables"
    iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
    iptables -I INPUT -p tcp --dport 80   -j ACCEPT
    iptables -I INPUT -p tcp --dport 443  -j ACCEPT
    iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
    iptables -I INPUT -p udp --dport 8472  -j ACCEPT
    apt-get install -y iptables-persistent -q
    netfilter-persistent save

    echo "==> Instalando K3s $K3S_VERSION"
    # --node-external-ip: a VNIC nao recebe mais IP publico efemero (o endereco
    # vem do IP reservado, anexado apos a criacao da instancia), entao o k3s nao
    # descobre sozinho o endereco externo e o node ficaria sem ExternalIP.
    # O CronJob traefik-patch-external-ip depende desse campo.
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
      --write-kubeconfig-mode 644 \
      --disable=traefik \
      --disable=servicelb \
      --node-external-ip "$PUBLIC_IP" \
      --tls-san "$PUBLIC_IP" \
      --tls-san "$DNS_NAME"

    echo "==> Aguardando K3s ficar Ready"
    until /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q " Ready"; do
      echo "  aguardando..."
      sleep 5
    done

    echo "==> K3s pronto"
    /usr/local/bin/kubectl get nodes
  EOF
  )
}
