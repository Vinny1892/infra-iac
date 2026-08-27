include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "vm" {
  config_path = "../../compute/vm"

  mock_outputs = {
    instance_public_ip = "1.2.3.4"
    instance_id        = "ocid1.instance.mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "output", "destroy"]
}

terraform {
  source = "../../../../../../../organisms/oci/k3s/helms"
}

# Helm + Kubernetes providers via local kubeconfig file
generate "k3s_provider" {
  path      = "k3s_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/k3s-oci.yaml"
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}
EOF
}

inputs = {
  # pathexpand normaliza o "~": sem ele, rodar terragrunt na mao (sem a env var
  # que o deploy.sh exporta ja expandida) muda o trigger do metallb_config e
  # forca uma recriacao desnecessaria.
  kubeconfig_path            = pathexpand(get_env("K3S_OCI_KUBECONFIG", "~/.kube/k3s-oci.yaml"))
  cloudflare_api_token       = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/Cloudflare API Token/credential")
  github_owner               = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/GitHub App/owner")
  github_app_id              = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/GitHub App/app_id")
  github_app_installation_id = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/GitHub App/installation_id")
  github_repo_name           = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/GitHub App/repo_name")
  github_app_private_key     = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/GitHub App/private_key")
  github_oauth_client_id     = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/GitHub OAuth ArgoCD/client_id")
  github_oauth_client_secret = run_cmd("--terragrunt-quiet", "op", "read","op://Lab-IAC/GitHub OAuth ArgoCD/client_secret")
  vm_public_ip               = dependency.vm.outputs.instance_public_ip
  vm_instance_id             = dependency.vm.outputs.instance_id
}
