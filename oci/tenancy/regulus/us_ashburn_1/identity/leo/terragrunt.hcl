include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))
}

# O dynamic group casa a VM do mercurio por OCID, e o OCID muda quando a VM e
# recriada — o que acontece de verdade (duas vezes em 04/09/2026). Por isso a
# dependencia: com ela, o `terragrunt apply` desta unit acompanha a recriacao em
# vez de deixar um grupo apontando para instancia que nao existe mais.
dependency "mercurio" {
  config_path = "../../applications/compute/mercurio"

  mock_outputs = {
    instance_id = "ocid1.instance.oc1.iad.mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "output", "destroy"]
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    variable "tenancy_ocid" {
      description = "OCID da tenancy. Dynamic group e policy vivem na raiz, nao num compartment."
      type        = string
    }

    variable "mercurio_instance_id" {
      description = "OCID da instancia do mercurio, a unica que o dynamic group aceita"
      type        = string
    }

    # Instance principal do Leo, o agente que roda na VM do mercurio.
    #
    # A REGRA CASA UMA INSTANCIA, NAO O COMPARTMENT. A alternativa obvia seria
    # `instance.compartment.id = '<tenancy>'`, que e estavel entre recriacoes e
    # nao precisaria da dependencia acima. Foi recusada: ela daria estes mesmos
    # poderes a TODA instancia da tenancy — incluindo a vm-regulus e a danebola,
    # que hospedam carga hostil de proposito (o honeypot Cowrie na porta 22).
    # Um Cowrie comprometido passaria a poder destruir as VMs do cluster.
    #
    # O custo de casar por OCID e ter de reaplicar quando a VM e recriada. A
    # dependencia no terragrunt resolve isso; um grupo apontando para instancia
    # morta simplesmente nao autentica ninguem, entao a falha e fechada.
    resource "oci_identity_dynamic_group" "leo" {
      compartment_id = var.tenancy_ocid
      name           = "leo-mercurio"
      description    = "Instance principal do agente Leo, na VM do mercurio"
      matching_rule  = "instance.id = '$${var.mercurio_instance_id}'"
    }

    # O que o Leo pode fazer na OCI.
    #
    # Este bloco e a UNICA fronteira entre o agente e a conta de nuvem: ele roda
    # com terminal.backend=local, ou seja, executa comando arbitrario sem
    # isolamento, e tem root na propria VM. Nao ha segunda camada atras disto.
    #
    # `manage all-resources` foi descartado de proposito, e o motivo nao e
    # gradualismo: aquele verbo inclui IAM, entao o Leo poderia reescrever esta
    # policy ou remover o acesso do dono. Fronteira que o sujeito pode reescrever
    # nao e fronteira. Por isso IAM fica fora, e so o dono muda o que vem abaixo.
    #
    # O que ele PODE destruir com o que esta liberado aqui: as tres VMs, todos os
    # block volumes (inclusive o disco de 100 GB do Longhorn, com os dados do
    # cluster), os IPs reservados e as regras da VCN. E consequencia aceita de
    # querer que ele administre o ambiente — mas convem saber o tamanho.
    #
    # O que NAO esta aqui: os backups do Longhorn e do Postgres vivem no S3 da
    # AWS, outra nuvem, fora do alcance desta policy. Sao o unico caminho de
    # volta se algo der errado por aqui — e por isso o alcance do Leo na AWS
    # merece a mesma analise que este arquivo faz da OCI.
    resource "oci_identity_policy" "leo" {
      compartment_id = var.tenancy_ocid
      name           = "leo-mercurio-lab"
      description    = "Permite ao agente Leo administrar compute, storage e rede do lab"

      statements = [
        # Instancias, VNICs, anexos, console e agente.
        "Allow dynamic-group $${oci_identity_dynamic_group.leo.name} to manage instance-family in tenancy",
        # Block volumes, anexos e backups de volume da OCI.
        "Allow dynamic-group $${oci_identity_dynamic_group.leo.name} to manage volume-family in tenancy",
        # VCN, subnets, gateways, route tables, security lists e IPs reservados.
        # E o que permite rodar o deploy.sh de ponta a ponta — e tambem o que
        # deixa alterar security list, entao ele consegue abrir porta ou cortar
        # o proprio acesso da rede.
        "Allow dynamic-group $${oci_identity_dynamic_group.leo.name} to manage virtual-network-family in tenancy",
        # Leitura ampla para inspecionar o que nao pode mudar, incluindo limites
        # e uso — util para ele saber que a franquia de A1 esta esgotada antes
        # de tentar criar uma quarta VM.
        "Allow dynamic-group $${oci_identity_dynamic_group.leo.name} to read all-resources in tenancy",
      ]
    }

    output "dynamic_group_name" {
      description = "Nome do dynamic group, usado nas statements da policy"
      value       = oci_identity_dynamic_group.leo.name
    }

    output "dynamic_group_id" {
      description = "OCID do dynamic group"
      value       = oci_identity_dynamic_group.leo.id
    }
  EOF
}

inputs = {
  tenancy_ocid         = local.region_vars.locals.compartment_id
  mercurio_instance_id = dependency.mercurio.outputs.instance_id
}
