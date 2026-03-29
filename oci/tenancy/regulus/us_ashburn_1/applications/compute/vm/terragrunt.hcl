include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars  = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))
  k3s_dns_name = "k3s.vinny.dev.br"
  k3s_version  = "v1.33.1+k3s1"

  user_data = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/k3s-install.log) 2>&1
    set -euo pipefail

    K3S_VERSION="${local.k3s_version}"
    DNS_NAME="${local.k3s_dns_name}"

    echo "==> Obtendo IP publico via IMDS"
    PUBLIC_IP=$(curl -sf -H "Authorization: Bearer Oracle" \
      "http://169.254.169.254/opc/v2/vnics/" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['publicIp'])" \
      2>/dev/null || curl -sf https://checkip.amazonaws.com)
    echo "PUBLIC_IP=$PUBLIC_IP"

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
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
      --write-kubeconfig-mode 644 \
      --disable=traefik \
      --disable=servicelb \
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

dependency "vcn" {
  config_path = "../../../network/vcn"

  mock_outputs = {
    subnet_public = [{ id = "ocid1.subnet.mock", availability_domain = "jnRJ:US-ASHBURN-AD-1" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../atoms/oci/compute/instance"
}

inputs = {
  compartment_id              = local.region_vars.locals.compartment_id
  availability_domain         = dependency.vcn.outputs.subnet_public[0].availability_domain
  subnet_id                   = dependency.vcn.outputs.subnet_public[0].id
  instance_name               = "vm-regulus"
  shape                       = "VM.Standard.A1.Flex"
  ocpus                       = 4
  memory_in_gbs               = 24
  image_id                    = local.region_vars.locals.image_id
  user_data_base64            = local.user_data
}
