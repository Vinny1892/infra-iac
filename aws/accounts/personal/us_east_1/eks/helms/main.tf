

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
  depends_on = [
    helm_release.ingress
  ]
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