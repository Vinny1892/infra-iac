include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Custom provider: AWS + Helm + Kubernetes + Cloudflare
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
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.41.0"
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

provider "cloudflare" {}
EOF
}

dependency "k3s_cluster" {
  config_path = "../cluster"

  mock_outputs = {
    cluster_endpoint           = "https://mock-nlb.amazonaws.com:6443"
    nlb_dns_name               = "mock-nlb.amazonaws.com"
    aws_lb_controller_role_arn = "arn:aws:iam::123456789012:role/mock"
    argocd_role_arn            = "arn:aws:iam::123456789012:role/mock"
    vpc_id                     = "vpc-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  aws_lb_controller_role_arn = dependency.k3s_cluster.outputs.aws_lb_controller_role_arn
  argocd_role_arn            = dependency.k3s_cluster.outputs.argocd_role_arn
  vpc_id                     = dependency.k3s_cluster.outputs.vpc_id
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
variable "aws_lb_controller_role_arn" {
  type = string
}

variable "argocd_role_arn" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type    = string
  default = ""
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

# =============================================================================
# cert-manager
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

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = false

  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.19.4"

  set {
    name  = "crds.enabled"
    value = "true"
  }

  values = [<<-YAML
    extraArgs:
      - "--dns01-recursive-nameservers-only"
      - "--dns01-recursive-nameservers=1.1.1.1:53,1.0.0.1:53"
    extraObjects:
      - |
        apiVersion: cert-manager.io/v1
        kind: ClusterIssuer
        metadata:
          name: letsencrypt-prod
        spec:
          acme:
            email: admin@vinny.dev.br
            server: https://acme-v02.api.letsencrypt.org/directory
            privateKeySecretRef:
              name: letsencrypt-prod-key
            solvers:
              - dns01:
                  cloudflare:
                    apiTokenSecretRef:
                      name: cloudflare-api-token
                      key: api-token
  YAML
  ]

  depends_on = [kubernetes_secret.cloudflare_api_token]
}

# =============================================================================
# Pod Identity Webhook (IRSA for K3s)
# =============================================================================

resource "helm_release" "pod_identity_webhook" {
  name       = "pod-identity-webhook"
  repository = "https://jkroepke.github.io/helm-charts"
  chart      = "amazon-eks-pod-identity-webhook"
  version    = "2.6.0"
  namespace  = "kube-system"
  timeout    = 600
  wait       = true

  set {
    name  = "fullnameOverride"
    value = "pod-identity-webhook"
  }

  depends_on = [helm_release.cert_manager]
}

# =============================================================================
# AWS Load Balancer Controller
# =============================================================================

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.1.0"
  namespace  = "kube-system"
  timeout    = 600
  wait       = true

  set {
    name  = "clusterName"
    value = "k3s"
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.aws_lb_controller_role_arn
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "region"
    value = "us-east-1"
  }

  depends_on = [helm_release.pod_identity_webhook]
}

# =============================================================================
# Traefik Ingress Controller
# =============================================================================

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "39.0.2"
  namespace        = "traefik"
  create_namespace = true
  timeout          = 600
  wait             = true

  set {
    name  = "service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # HTTP -> HTTPS redirect (Traefik chart v39+ schema)
  set {
    name  = "ports.web.http.redirections.entryPoint.to"
    value = "websecure"
  }

  set {
    name  = "ports.web.http.redirections.entryPoint.scheme"
    value = "https"
  }

  set {
    name  = "ports.web.http.redirections.entryPoint.permanent"
    value = "true"
  }

  set {
    name  = "providers.kubernetesCRD.enabled"
    value = "true"
  }

  set {
    name  = "providers.kubernetesIngress.enabled"
    value = "true"
  }

  set {
    name  = "logs.general.level"
    value = "INFO"
  }

  depends_on = [helm_release.aws_lb_controller]
}

# =============================================================================
# ArgoCD
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

  # TLS terminado no Traefik — ArgoCD serve HTTP puro
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  set {
    name  = "server.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.argocd_role_arn
  }

  depends_on = [helm_release.traefik]
}

# =============================================================================
# cert-manager: Cloudflare secret + ClusterIssuer
# =============================================================================


# =============================================================================
# Certificates (Let's Encrypt via DNS-01 Cloudflare)
# =============================================================================

resource "kubernetes_manifest" "cert_argocd" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "argocd-k3s-vinny-dev-br"
      namespace = "argocd"
    }
    spec = {
      secretName = "argocd-k3s-tls"
      issuerRef = {
        name = "letsencrypt-prod"
        kind = "ClusterIssuer"
      }
      dnsNames = ["argocd-k3s.vinny.dev.br"]
    }
  }

  depends_on = [helm_release.cert_manager, helm_release.argocd]
}

resource "kubernetes_manifest" "cert_whoami" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "k3s-vinny-dev-br"
      namespace = "whoami"
    }
    spec = {
      secretName = "k3s-tls"
      issuerRef = {
        name = "letsencrypt-prod"
        kind = "ClusterIssuer"
      }
      dnsNames = ["k3s.vinny.dev.br"]
    }
  }

  depends_on = [helm_release.cert_manager, kubernetes_namespace.whoami]
}

# =============================================================================
# Cloudflare DNS
# =============================================================================

data "kubernetes_service" "traefik" {
  metadata {
    name      = "traefik"
    namespace = "traefik"
  }

  depends_on = [helm_release.traefik]
}

module "k3s_domain" {
  source             = "../../../../../../../atoms/cloudflare/domain"
  cloudflare_zone_id = var.cloudflare_zone_id
  dns = {
    name    = "k3s"
    content = data.kubernetes_service.traefik.status[0].load_balancer[0].ingress[0].hostname
    type    = "CNAME"
  }
  proxiable = false
}

module "argocd_domain" {
  source             = "../../../../../../../atoms/cloudflare/domain"
  cloudflare_zone_id = var.cloudflare_zone_id
  dns = {
    name    = "argocd-k3s"
    content = data.kubernetes_service.traefik.status[0].load_balancer[0].ingress[0].hostname
    type    = "CNAME"
  }
  proxiable = false
}

# =============================================================================
# IngressRoute - ArgoCD (subdomínio dedicado)
# =============================================================================

resource "kubernetes_manifest" "argocd_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "argocd"
      namespace = "argocd"
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`argocd-k3s.vinny.dev.br`)"
        kind  = "Rule"
        services = [{
          name = "argocd-server"
          port = 80
        }]
      }]
      tls = {
        secretName = "argocd-k3s-tls"
      }
    }
  }

  depends_on = [helm_release.argocd, helm_release.traefik, kubernetes_manifest.cert_argocd]
}

# =============================================================================
# Whoami - Validation App
# =============================================================================

resource "kubernetes_namespace" "whoami" {
  metadata {
    name = "whoami"
  }
}

resource "kubernetes_deployment" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.whoami.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "whoami"
      }
    }

    template {
      metadata {
        labels = {
          app = "whoami"
        }
      }

      spec {
        container {
          name  = "whoami"
          image = "traefik/whoami:v1.11.0"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.whoami.metadata[0].name
  }

  spec {
    selector = {
      app = "whoami"
    }

    port {
      port        = 80
      target_port = 80
    }
  }
}

resource "kubernetes_manifest" "whoami_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "whoami"
      namespace = "whoami"
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`k3s.vinny.dev.br`) && PathPrefix(`/whoami`)"
        kind  = "Rule"
        services = [{
          name = "whoami"
          port = 80
        }]
      }]
      tls = {
        secretName = "k3s-tls"
      }
    }
  }

  depends_on = [
    helm_release.traefik,
    kubernetes_service.whoami,
    kubernetes_manifest.cert_whoami
  ]
}
EOF
}
