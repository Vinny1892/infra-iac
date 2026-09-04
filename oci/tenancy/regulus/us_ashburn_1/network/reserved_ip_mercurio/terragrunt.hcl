include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))
}

# Segundo IP reservado da tenancy, dedicado ao mercurio.
#
# Existe como unit separada, e nao como segundo recurso na unit `reserved_ip`,
# porque o ciclo de vida e independente: o mercurio sai do cluster e passa a viver
# numa VM propria, que pode ser destruida e recriada sem tocar no k3s. Unit
# separada tambem significa state separado — um destroy do mercurio nao chega perto
# do endereco que serve o cluster.
#
# O motivo de nao reaproveitar o IP do k3s: aquele endereco hospeda o honeypot na
# porta 22 e leva varredura hostil o dia inteiro, acumulando reputacao ruim em
# blocklist. Servir o mercurio pelo mesmo IP herdaria essa reputacao.
generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    variable "compartment_id" {
      description = "OCID do compartment onde o IP reservado sera criado"
      type        = string
    }

    variable "display_name" {
      description = "Nome do IP publico reservado"
      type        = string
    }

    # IP publico reservado criado SEM vinculo com VNIC, pelo mesmo motivo da
    # unit `reserved_ip`: o endereco fica conhecido em tempo de apply, antes da
    # instancia existir, o que permite injeta-lo no user_data sem descoberta em
    # runtime. A associacao com a VNIC e feita pela unit da VM.
    resource "oci_core_public_ip" "this" {
      compartment_id = var.compartment_id
      display_name   = var.display_name
      lifetime       = "RESERVED"

      # A unit da VM anexa o IP a uma VNIC. Sem isto, todo apply daqui
      # enxergaria o vinculo como drift e desanexaria o IP.
      lifecycle {
        ignore_changes = [private_ip_id]
      }
    }

    output "public_ip_id" {
      description = "OCID do IP publico reservado"
      value       = oci_core_public_ip.this.id
    }

    output "public_ip_address" {
      description = "Endereco IPv4 reservado, estavel entre ciclos de destroy/deploy da VM do mercurio"
      value       = oci_core_public_ip.this.ip_address
    }
  EOF
}

inputs = {
  compartment_id = local.region_vars.locals.compartment_id
  display_name   = "mercurio-reserved-ip"
}
