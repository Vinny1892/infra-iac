include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))
}

terraform {
  source = "../../../../../../atoms/oci/network/vcn"
}

inputs = {
  compartment_id             = local.region_vars.locals.compartment_id
  vcn_cidr_block             = "10.20.0.0/16"
  public_subnet_cidr_blocks  = ["10.20.1.0/24", "10.20.2.0/24"]
  private_subnet_cidr_blocks = ["10.20.3.0/24", "10.20.4.0/24"]
  availability_domains       = ["jnRJ:US-ASHBURN-AD-1", "jnRJ:US-ASHBURN-AD-2"]
  vcn_name                   = "MainVCN"

  # Sem IP residencial fixo desde a troca de provedor: o SSH real nao tem mais
  # como ser restringido por CIDR. A compensacao e sair da 22 (porta alta), so
  # chave publica no sshd e o Cowrie ocupando a 22 como sensor.
  ssh_allowed_cidr = "0.0.0.0/0"
  ssh_port         = 62222

  additional_ingress_rules = [
    { source = "0.0.0.0/0", protocol = "6", tcp_options = { min = 80, max = 80 } },
    { source = "0.0.0.0/0", protocol = "6", tcp_options = { min = 443, max = 443 } },
    # Minecraft Java. O RCON (25575) continua exclusivamente interno no K3s.
    { source = "0.0.0.0/0", protocol = "6", tcp_options = { min = 25565, max = 25565 } },
    { source = "0.0.0.0/0", protocol = "6", tcp_options = { min = 6443, max = 6443 } },
    # Honeypot: a 22 nao serve mais SSH real, o trafego cai no Cowrie (hostPort
    # 22 -> containerPort 2222) no namespace honeypot.
    { source = "0.0.0.0/0", protocol = "6", tcp_options = { min = 22, max = 22 }, description = "Honeypot Cowrie" },
  ]
}
