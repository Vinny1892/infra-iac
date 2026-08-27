include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))
}

dependency "compartment" {
  config_path = "../../identity/compartment"

  mock_outputs = {
    compartment_id = "ocid1.compartment.mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../atoms/oci/network/vcn"
}

# CIDR distinto do agrostack (10.20.0.0/16). Não há peering entre as duas redes,
# então o overlap não quebraria nada — mas manter distinto deixa a porta aberta
# para peering futuro sem renumerar.
inputs = {
  compartment_id             = dependency.compartment.outputs.compartment_id
  vcn_cidr_block             = "10.30.0.0/16"
  public_subnet_cidr_blocks  = ["10.30.1.0/24"]
  private_subnet_cidr_blocks = ["10.30.2.0/24"]
  availability_domains       = ["jnRJ:US-ASHBURN-AD-1"]
  vcn_name                   = "PessoalVCN"
  dns_label                  = "pessoal"
  ssh_allowed_cidr           = local.region_vars.locals.admin_cidr

  additional_ingress_rules = [
    { source = "0.0.0.0/0", protocol = "17", udp_options = { min = 51820, max = 51820 }, description = "WireGuard" },
    { source = "0.0.0.0/0", protocol = "6", tcp_options = { min = 25565, max = 25565 }, description = "Minecraft Java" },
    { source = "0.0.0.0/0", protocol = "17", udp_options = { min = 9987, max = 9987 }, description = "TeamSpeak 6 - voz" },
    { source = "0.0.0.0/0", protocol = "6", tcp_options = { min = 30033, max = 30033 }, description = "TeamSpeak 6 - transferencia de arquivo" },
    # Web query do TS6 (10080) fica fechada de propósito: administração entra pela VPN.
    # Minecraft Bedrock, se um dia entrar, precisa de 19132/udp.
  ]
}
