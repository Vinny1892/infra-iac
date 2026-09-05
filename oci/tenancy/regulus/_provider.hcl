generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= v1.9.2"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  region = "us-ashburn-1"
  # O fluxo humano preserva APIKey (config local da OCI). O deploy automatizado
  # exporta OCI_TERRAFORM_AUTH=InstancePrincipal, pois roda dentro de uma VM OCI
  # autorizada por dynamic group e nao possui tenancy/user/key do operador.
  auth = "${get_env("OCI_TERRAFORM_AUTH", "APIKey")}"
}
EOF
}
