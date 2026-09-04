# =============================================================================
# MetalLB - Load Balancer para K3s
# =============================================================================

resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = "0.16.1"
  namespace        = "metallb-system"
  create_namespace = true
  timeout          = 600
  wait             = false
  wait_for_jobs    = false

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

  # instance_id e o unico trigger que muda quando a VM e recriada. O vm_ip virou
  # constante depois que o IP passou a ser reservado, e o kubeconfig_path sempre
  # foi fixo — sem instance_id, um destroy que falhe em limpar o state faz o
  # Terraform pular este recurso e o cluster novo fica sem as CRs do MetalLB.
  triggers = {
    vm_instance_id = var.vm_instance_id
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

      # Endpoint existir NAO significa webhook servindo. A versao anterior
      # esperava o Service ter endereco e imprimia "MetalLB webhook ready" — e o
      # apply logo abaixo tomava 502 do proxy do apiserver mesmo assim:
      #   failed calling webhook "ipaddresspoolvalidationwebhook.metallb.io":
      #   proxy error from 127.0.0.1:6443 while dialing 10.42.0.5:9443, code 502
      # A condicao que importa e o apply ser aceito, entao e ele que se repete.
      manifest=$(mktemp)
      cat >"$manifest" <<'EOF'
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

      for i in $(seq 1 60); do
        if kubectl --kubeconfig "${var.kubeconfig_path}" apply -f "$manifest"; then
          echo "CRs do MetalLB aplicadas."
          rm -f "$manifest"
          exit 0
        fi
        echo "Webhook do MetalLB ainda nao aceita o apply ($i/60); aguardando 5s..."
        sleep 5
      done

      rm -f "$manifest"
      echo "ERRO: webhook do MetalLB nao aceitou as CRs apos 5 minutos."
      exit 1
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
  version    = "v1.21.1"
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
  version          = "1.12.1"
  namespace        = "longhorn-system"
  create_namespace = true
  # Menor que os demais releases de proposito. Com `wait = false` a instalacao
  # retorna na hora, entao este timeout governa quase so a remocao: e o teto de
  # espera pelo job longhorn-uninstall. O pre-destroy.sh ja drena os volumes
  # antes, entao o uninstall deve ser rapido — se passar disto, algo esta errado
  # e falhar em 3 min e melhor que penar 10 antes do mesmo desfecho.
  timeout = 180
  wait    = false

  values = [
    yamlencode({
      defaultSettings = {
        # 2 desde o split em vm-regulus + danebola, e tem de bater com
        # argocd/values/longhorn.yaml: se divergirem, o selfHeal corrige depois
        # do primeiro sync e a diferenca aparece como valor que "voltou sozinho"
        # apos um apply bem-sucedido.
        defaultReplicaCount = 2
        # Sem esta flag o job longhorn-uninstall se recusa a concluir e o
        # `terragrunt destroy` falha com BackoffLimitExceeded, deixando o
        # longhorn e o cert-manager (preso por depends_on) orfaos no state.
        # E uma trava contra apagar storage sem querer: aceitavel aqui porque
        # este cluster e recriado do zero a cada ciclo e nao guarda dado
        # persistente. NAO replicar em cluster com dado que importa.
        deletingConfirmationFlag = true
      }

      # A StorageClass criada pelo seed tambem precisa da contagem certa.
      # Faltando isto, ela nasce com o default do chart — tres replicas — e todo
      # PVC criado entre o seed e o primeiro sync do ArgoCD fica Degraded, sem
      # onde por a terceira copia. O restore_minecraft_data do deploy.sh cria
      # PVC exatamente nessa janela.
      persistence = {
        defaultClassReplicaCount = 2
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
  version          = "10.4.2"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600
  wait             = false
  wait_for_jobs    = false

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  values = [
    yamlencode({
      configs = {
        secret = {
          extra = {
            "dex.github.clientID"     = var.github_oauth_client_id
            "dex.github.clientSecret" = var.github_oauth_client_secret
          }
        }
      }
    })
  ]

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

# External Secrets Operator.
#
# Inverte o modelo do bootstrap: em vez de um script ler o 1Password uma vez no
# deploy e criar Secrets que ninguem mais vigia, o ESO reconcilia continuamente
# a partir de ExternalSecrets versionados no git. Secret apagado volta; valor
# rotacionado no cofre se propaga.
#
# Fica no seed, e nao so no ArgoCD, porque os ExternalSecrets das Applications
# precisam de um controller de pe para serem resolvidos.
resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

# O unico segredo que ainda precisa ser injetado de fora: e a credencial que
# permite buscar todas as outras. O ovo da galinha nao desaparece — mas encolhe
# de varios Secrets para um.
resource "kubernetes_secret" "onepassword_token" {
  metadata {
    name      = "onepassword-token"
    namespace = "external-secrets"
  }

  data = {
    token = var.onepassword_service_account_token
  }

  type       = "Opaque"
  depends_on = [kubernetes_namespace.external_secrets]
}

# O chart do ESO NAO e instalado aqui, so pelo ArgoCD (app external-secrets,
# wave -6). Diferente dos demais componentes, nada no seed depende dele: quem
# consome ExternalSecret sao as Applications, que ja vem depois do ArgoCD.
#
# Instalar nos dois lugares quebrava o apply. O ArgoCD chega primeiro, aplica os
# manifests direto e sem as anotacoes de posse do Helm; o helm_release entao
# recusa adotar o que encontra:
#   ServiceAccount "external-secrets-cert-controller" exists and cannot be
#   imported into the current release: missing key "meta.helm.sh/release-name"
#
# Por isso o seed se limita ao que o ArgoCD nao tem como criar: o namespace e o
# Secret com o token, que precisa vir de fora do cluster.
