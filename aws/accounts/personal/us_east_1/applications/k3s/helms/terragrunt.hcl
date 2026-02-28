include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Custom provider: AWS + Helm + Kubernetes
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

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

dependency "k3s_cluster" {
  config_path = "../cluster"

  mock_outputs = {
    argocd_role_arn = "arn:aws:iam::123456789012:role/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  argocd_role_arn = dependency.k3s_cluster.outputs.argocd_role_arn
}

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

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "argocd_role_arn" {
  type = string
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

# =============================================================================
# Bootstrap: Namespaces + Secrets (created before ArgoCD exists)
# =============================================================================

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_secret" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "cert-manager"
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.cert_manager]
}

resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret" "cloudflare_api_token_eds" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "external-dns"
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.external_dns]
}

# =============================================================================
# ArgoCD — seed install (self-managed instance takes over via App of Apps)
# =============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.4.5"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600
  wait             = true

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # TLS terminated at Traefik — ArgoCD serves plain HTTP
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  set {
    name  = "server.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.argocd_role_arn
  }
}
EOF
}
