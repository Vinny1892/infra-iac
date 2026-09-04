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
    # Tráfego interno da VCN, liberado por inteiro. Duas razões independentes:
    #
    # 1. O cluster de dois nodes precisa disso. O agent da danebola alcança a
    #    API na 6443 só porque ela está aberta ao mundo — por acaso, não por
    #    desenho. Mas 8472/udp (VXLAN do flannel) e 10250 (kubelet) não tinham
    #    regra nenhuma: sem elas a rede pod-a-pod entre nodes não sobe, o
    #    `kubectl logs` em pod da danebola falha e o Longhorn não replica entre
    #    os nodes. O iptables das duas VMs já libera essas portas; quem barrava
    #    era só a security list.
    #
    # 2. É o caminho de administração do mercurio, que alcança regulus e
    #    danebola pelos IPs privados, sem depender de porta aberta na internet.
    #    A regra usa o CIDR da VCN e não o host: o IP privado do mercurio muda
    #    a cada recriação da VM (visto em 04/09/2026), então uma regra por host
    #    passaria a apontar para endereço de ninguém no primeiro replace.
    #
    # `protocol = "all"` e não uma lista de portas: enumerar as portas do k3s
    # aqui seria uma segunda fonte da verdade para brigar com o iptables de cada
    # host, que é onde a diferenciação por VM realmente acontece.
    { source = "10.20.0.0/16", protocol = "all", description = "Trafego interno da VCN (k3s entre nodes + administracao pelo mercurio)" },
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
