include "root" {
  path = find_in_parent_folders("root.hcl")
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
  kubeconfig_path            = get_env("K3S_OCI_KUBECONFIG", "~/.kube/k3s-oci.yaml")
  cloudflare_api_token       = get_env("CLOUDFLARE_API_TOKEN", "")
  github_owner               = get_env("GITHUB_OWNER", "")
  github_app_id              = get_env("GITHUB_APP_ID", "")
  github_app_installation_id = get_env("GITHUB_APP_INSTALL_ID", "")
  github_repo_name           = get_env("GITHUB_REPO_NAME", "infra-iac")
  github_app_private_key     = get_env("GITHUB_APP_PRIVATE_KEY", "")
}
