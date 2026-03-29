# =============================================================================
# Bootstrap: Namespaces + Secrets (created before ArgoCD exists)
# =============================================================================

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_secret" "cloudflare_cert_manager" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "cert-manager"
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  type       = "Opaque"
  depends_on = [kubernetes_namespace.cert_manager]
}

resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret" "cloudflare_external_dns" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "external-dns"
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  type       = "Opaque"
  depends_on = [kubernetes_namespace.external_dns]
}

# =============================================================================
# cert-manager — pre-deployed before ArgoCD App of Apps
# ArgoCD adopts and manages updates via argocd/apps/cert-manager.yaml
# =============================================================================

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.19.4"
  namespace  = "cert-manager"
  timeout    = 300
  wait       = true

  values = [
    yamlencode({
      crds = { enabled = true }
      extraArgs = [
        "--dns01-recursive-nameservers-only",
        "--dns01-recursive-nameservers=1.1.1.1:53,1.0.0.1:53"
      ]
    })
  ]

  depends_on = [kubernetes_namespace.cert_manager]
}

# =============================================================================
# Longhorn — distributed storage (single-node: replicas=1)
# Pre-deployed so PVCs are available when ArgoCD starts
# =============================================================================

resource "helm_release" "longhorn" {
  name             = "longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = "1.7.3"
  namespace        = "longhorn-system"
  create_namespace = true
  timeout          = 600
  wait             = true

  values = [
    yamlencode({
      defaultSettings = {
        defaultReplicaCount = 1
      }
    })
  ]

  depends_on = [helm_release.cert_manager]
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
  wait_for_jobs    = false

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # TLS terminated at Traefik — ArgoCD serves plain HTTP
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  depends_on = [helm_release.longhorn]
}

# =============================================================================
# ArgoCD Repository Configuration (via Secret — GitHub App auth)
# =============================================================================

resource "kubernetes_secret" "argocd_repo" {
  metadata {
    name      = "repo-infra-iac-private"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  type = "Opaque"

  data = {
    type                    = "git"
    url                     = "https://github.com/${var.github_owner}/${var.github_repo_name}"
    githubAppID             = var.github_app_id
    githubAppInstallationID = var.github_app_installation_id
    githubAppPrivateKey     = var.github_app_private_key
  }

  depends_on = [helm_release.argocd]
}
