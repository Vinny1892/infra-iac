terraform {
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
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  access_key                  = "mock"
  secret_key                  = "mock"
}

provider "helm" {
  kubernetes {
    host = "http://localhost:8080"
  }
}

provider "kubernetes" {
  host = "http://localhost:8080"
}

provider "github" {
  owner = var.github_owner
}

variable "argocd_role_arn" {
  type    = string
  default = "arn:aws:iam::123456789012:role/mock"
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = "mock-token"
}

variable "github_owner" {
  type    = string
  default = "mock-owner"
}

variable "github_app_id" {
  type    = string
  default = "12345"
}

variable "github_app_installation_id" {
  type    = string
  default = "67890"
}

# =============================================================================
# GitHub App Key Generation (Mocked for tests)
# =============================================================================

# resource "github_app_private_key" "vega" {
#   app_id = var.github_app_id
# }

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
  wait             = false

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

# =============================================================================
# ArgoCD Repository Configuration (via Secret)
# =============================================================================

resource "kubernetes_secret" "argocd_repo_vega" {
  metadata {
    name      = "repo-vega-private"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  type = "Opaque"

  data = {
    type                    = "git"
    url                     = "https://github.com/${var.github_owner}"
    githubAppID             = var.github_app_id
    githubAppInstallationID = var.github_app_installation_id
    githubAppPrivateKey     = "mock-private-key"
  }

  depends_on = [helm_release.argocd]
}
