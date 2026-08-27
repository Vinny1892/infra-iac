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
  source = "../../../../../../../atoms/oci/identity/compartment"
}

inputs = {
  parent_compartment_id = local.region_vars.locals.tenancy_id
  name                  = "pessoal"
  description           = "Uso pessoal — Minecraft, TeamSpeak 6, WireGuard. Isolado do agrostack."

  freeform_tags = {
    projeto = "pessoal"
  }
}
