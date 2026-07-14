# =============================================================================
# MetalLB - Load Balancer para K3s
# =============================================================================

resource "helm_release" "metallb" {
  name       = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  version    = "0.14.8"
  namespace  = "metallb-system"
  create_namespace = true
  timeout    = 600
  wait       = false
  wait_for_jobs = false

  values = [
    yamlencode({
      speaker = {
        tolerations = [
          {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
      }
    })
  ]
}

resource "null_resource" "metallb_config" {
  depends_on = [helm_release.metallb]

  triggers = {
    vm_ip          = var.vm_public_ip
    kubeconfig     = var.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      # Wait for MetalLB CRDs to be registered
      for i in $(seq 1 30); do
        if kubectl --kubeconfig "${var.kubeconfig_path}" get crd ipaddresspools.metallb.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for MetalLB CRDs... ($i/30)"
        sleep 5
      done

      # Wait for MetalLB webhook to be ready
      for i in $(seq 1 60); do
        if kubectl --kubeconfig "${var.kubeconfig_path}" -n metallb-system get endpoints metallb-webhook-service -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
          echo "MetalLB webhook ready."
          break
        fi
        echo "Waiting for MetalLB webhook... ($i/60)"
        sleep 5
      done

      kubectl --kubeconfig "${var.kubeconfig_path}" apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - "${var.vm_public_ip}-${var.vm_public_ip}"
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF
    SCRIPT
  }
}

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
  wait       = false

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
  wait             = false

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
