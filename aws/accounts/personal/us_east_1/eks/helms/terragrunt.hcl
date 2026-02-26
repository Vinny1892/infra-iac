include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Custom provider: uses profile "sandim-account" + helm provider
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= v1.9.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "sandim-account"
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

dependency "eks" {
  config_path = "../"

  mock_outputs = {
    cluster_endpoint = "https://mock.eks.amazonaws.com"
    cluster_name     = "mock-cluster"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
data "aws_eks_cluster" "cluster" {
  name = "my-eks-cluster"
}

data "aws_eks_cluster_auth" "cluster_auth" {
  name = data.aws_eks_cluster.cluster.name
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster_auth.token
  }
}

resource "helm_release" "ingress" {
  name          = "ingress-nginx"
  chart         = "ingress-nginx"
  repository    = "https://kubernetes.github.io/ingress-nginx"
  timeout       = 600
  wait_for_jobs = false
  wait          = false
  recreate_pods = true
  version       = "4.11.3"
}

resource "helm_release" "cert_manager" {
  repository       = "https://charts.jetstack.io"
  name             = "cert-manager"
  chart            = "cert-manager"
  create_namespace = true
  namespace        = "cert-manager"
  timeout          = 600
  version          = "v1.16.1"
  recreate_pods    = true
  wait             = false
  set {
    name  = "installCRDs"
    value = "true"
  }
  depends_on = [helm_release.ingress]
}

resource "helm_release" "external_secret" {
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  name             = "external-secrets"
  timeout          = 600
  version          = "v0.10.4"
  create_namespace = true
  namespace        = "external-secret"
  recreate_pods    = true
  wait             = false
  depends_on = [
    helm_release.ingress,
    helm_release.cert_manager
  ]
}
EOF
}
