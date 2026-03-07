data "aws_secretsmanager_secret_version" "github_app_private_key" {
  secret_id = "github-app-private-key"
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
    url                     = "https://github.com/${var.github_owner}/${var.github_repo_name}"
    githubAppID             = var.github_app_id
    githubAppInstallationID = var.github_app_installation_id
    githubAppPrivateKey     = jsondecode(data.aws_secretsmanager_secret_version.github_app_private_key.secret_string)["github-app-private-key"]
  }

  depends_on = [helm_release.argocd]
}
