include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../organisms/aws/k3s/helms"
}

# AWS provider — reads kubeconfig from SSM
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      managed_by  = "terraform"
      environment = "testing"
      account     = "personal"
    }
  }
}
EOF
}

# Kubernetes/Helm providers — configured from kubeconfig stored in SSM
generate "k3s_provider" {
  path      = "k3s_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
data "aws_ssm_parameter" "kubeconfig" {
  name            = "/k3s/kubeconfig"
  with_decryption = true
}

locals {
  kubeconfig = yamldecode(data.aws_ssm_parameter.kubeconfig.value)
}

provider "helm" {
  kubernetes {
    host                   = local.kubeconfig.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kubeconfig.users[0].user["client-certificate-data"])
    client_key             = base64decode(local.kubeconfig.users[0].user["client-key-data"])
  }
}

provider "kubernetes" {
  host                   = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kubeconfig.users[0].user["client-certificate-data"])
  client_key             = base64decode(local.kubeconfig.users[0].user["client-key-data"])
}
EOF
}

dependency "k3s_cluster" {
  config_path = "../cluster"

  mock_outputs = {
    argocd_role_arn = "arn:aws:iam::123456789012:role/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  argocd_role_arn            = dependency.k3s_cluster.outputs.argocd_role_arn
  github_owner               = run_cmd("op", "read", "op://Lab-IAC/GitHub App/owner")
  github_app_id              = run_cmd("op", "read", "op://Lab-IAC/GitHub App/app_id")
  github_app_installation_id = run_cmd("op", "read", "op://Lab-IAC/GitHub App/installation_id")
  github_repo_name           = run_cmd("op", "read", "op://Lab-IAC/GitHub App/repo_name")
}
