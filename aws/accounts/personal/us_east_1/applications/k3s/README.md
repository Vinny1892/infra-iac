# K3s Cluster on AWS

Cluster Kubernetes leve (K3s) rodando em EC2 na AWS, com RDS PostgreSQL como datastore, IRSA para autenticacao de pods, e ArgoCD gerenciando todos os workloads via GitOps (App of Apps).

## Indice

- [Arquitetura](#arquitetura)
- [Pre-requisitos](#pre-requisitos)
- [Credenciais](#credenciais)
- [Instalacao](#instalacao)
- [Estrutura de Diretorios](#estrutura-de-diretorios)
- [Componentes](#componentes)
- [Decisoes de Arquitetura](#decisoes-de-arquitetura)
- [Operacoes do Dia-a-dia](#operacoes-do-dia-a-dia)
- [Troubleshooting](#troubleshooting)
- [Destruicao](#destruicao)
- [Versoes](#versoes)

---

## Arquitetura

```
                   ┌──────────────────────────────────────────────────────┐
                   │                    AWS (us-east-1)                   │
                   │                                                      │
  Internet ──────► │  NLB (:6443) ──► EC2 ASG (K3s masters)              │
                   │                      │                               │
                   │                      ├── K3s (Kubernetes)            │
                   │                      │     ├── ArgoCD (GitOps)       │
                   │                      │     ├── Traefik (Ingress)     │
                   │                      │     ├── cert-manager (TLS)    │
                   │                      │     ├── ExternalDNS (DNS)     │
                   │                      │     ├── AWS LB Controller     │
                   │                      │     └── whoami (validacao)    │
                   │                      │                               │
                   │                      └── RDS PostgreSQL (datastore)  │
                   │                                                      │
                   │  S3 (OIDC discovery) ── IAM OIDC Provider (IRSA)    │
                   │  SSM Parameter Store ── /k3s/kubeconfig             │
                   └──────────────────────────────────────────────────────┘
                                          │
                                    Cloudflare DNS
                                  ┌───────┴────────┐
                                  │  vinny.dev.br   │
                                  │  k3s.vinny.dev.br
                                  │  argocd-k3s.vinny.dev.br
                                  └────────────────┘
```

**Fluxo de deploy:**

```
Terraform (cluster/)             Terraform (helms/)              ArgoCD (GitOps, auto-sync)
─────────────────────            ────────────────────            ──────────────────────────
EC2, RDS, NLB, IAM, OIDC   →    ArgoCD seed install        →   App of Apps gerencia:
Security Groups, IRSA roles      Namespaces + Secrets             cert-manager, pod-identity,
                                                                  aws-lb-controller, external-dns,
                                                                  traefik, argocd (self-managed),
                                                                  whoami
```

---

## Pre-requisitos

### Ferramentas

| Ferramenta   | Versao minima | Instalacao                                     |
|--------------|---------------|-------------------------------------------------|
| Terraform    | >= 1.9.2      | https://developer.hashicorp.com/terraform       |
| Terragrunt   | >= 0.55       | https://terragrunt.gruntwork.io                 |
| AWS CLI      | v2            | https://docs.aws.amazon.com/cli/latest/userguide |
| kubectl      | >= 1.28       | https://kubernetes.io/docs/tasks/tools           |
| yq           | v4            | https://github.com/mikefarah/yq                 |
| jq           | >= 1.6        | https://jqlang.github.io/jq                     |

`yq` e `jq` sao necessarios para o `deploy.sh generate-values` que extrai outputs do Terraform e escreve nos values files do ArgoCD.

### Infraestrutura AWS pre-existente

O cluster depende de recursos criados por outros units do Terragrunt:

- **VPC** (`aws/.../network/vpc/`) — VPC, subnets publicas e privadas, CIDR
- **AWS Profile** `personal` configurado no AWS CLI

### Acesso ao repositorio Git

O ArgoCD precisa acessar este repositorio para sincronizar os manifests. Antes do primeiro deploy, configure o acesso:

```bash
# Opcao 1: Secret com Personal Access Token
kubectl -n argocd create secret generic infra-iac-repo \
  --from-literal=url=https://github.com/Vinny1892/infra-iac.git \
  --from-literal=password=<GITHUB_PAT> \
  --from-literal=username=git \
  --from-literal=type=git
kubectl -n argocd label secret infra-iac-repo argocd.argoproj.io/secret-type=repository

# Opcao 2: Tornar o repo publico (sem secret necessario)
```

---

## Credenciais

### Mapa de credenciais

| Credencial              | Onde e configurada                | Onde e usada                                    | Motivo                                                     |
|-------------------------|-----------------------------------|-------------------------------------------------|------------------------------------------------------------|
| `AWS_PROFILE=personal`  | `~/.aws/credentials`             | Terraform, AWS CLI, deploy.sh                   | Autenticacao com a AWS para criar/gerenciar recursos       |
| `CLOUDFLARE_API_TOKEN`  | Variavel de ambiente             | Terraform (`TF_VAR_cloudflare_api_token`)       | Criacao de K8s secrets para cert-manager e ExternalDNS     |
| Kubeconfig              | SSM `/k3s/kubeconfig`            | Terraform providers (helm/kubernetes), kubectl  | Acesso ao cluster K3s (gerado automaticamente pelo master) |
| RDS password            | AWS Secrets Manager (gerenciado) | K3s datastore (recuperado no boot da EC2)       | Conexao K3s → PostgreSQL (nunca em plain-text no TF state) |
| Let's Encrypt key       | K8s Secret `letsencrypt-prod-key`| cert-manager                                    | Chave privada ACME para emitir certificados TLS            |
| IRSA roles              | IAM (criadas pelo `cluster/`)    | Pods via ServiceAccount annotations             | Permissoes AWS para LB Controller e ArgoCD sem credentials |

### Como carregar as credenciais

Antes de rodar qualquer comando, as seguintes variaveis de ambiente precisam estar setadas:

```bash
export AWS_PROFILE=personal
export CLOUDFLARE_API_TOKEN="<seu-token-cloudflare>"
```

O `deploy.sh` tenta carrega-las automaticamente se nao estiverem setadas. Para verificar:

```bash
echo $AWS_PROFILE            # → personal
echo $CLOUDFLARE_API_TOKEN   # → cfp_... (token da API Cloudflare)
aws sts get-caller-identity  # → confirma acesso AWS
```

### Cloudflare API Token

O token precisa de permissoes:
- **Zone:DNS:Edit** — para cert-manager (DNS-01 challenge) e ExternalDNS (criar/deletar registros)
- **Zone:Zone:Read** — para listar zonas

O mesmo token e injetado em dois K8s secrets (um por namespace):
- `cert-manager/cloudflare-api-token` — usado pelo ClusterIssuer para validar dominio via DNS-01
- `external-dns/cloudflare-api-token` — usado pelo ExternalDNS para criar registros CNAME automaticamente

Ambos os secrets sao criados pelo Terraform (`helms/terragrunt.hcl`) **antes** do ArgoCD existir e nao tem labels do ArgoCD, entao nao sao prunados.

### IRSA (IAM Roles for Service Accounts)

O K3s nao tem IRSA nativo como o EKS. A solucao:

1. **OIDC Discovery** — S3 bucket publico com `.well-known/openid-configuration` e JWKS
2. **IAM OIDC Provider** — Registrado na AWS com o thumbprint do certificado do S3
3. **Pod Identity Webhook** — Mutating webhook que injeta env vars `AWS_ROLE_ARN` e `AWS_WEB_IDENTITY_TOKEN_FILE` nos pods
4. **IAM Roles** — Trust policy federada com o OIDC provider, condicionada ao ServiceAccount

Roles IRSA criadas:
- `k3s-aws-lb-controller` — Permissoes para criar NLBs, Target Groups, Security Groups
- `k3s-argocd` — Permissoes basicas para ArgoCD acessar recursos AWS

---

## Instalacao

### Deploy completo (do zero)

```bash
cd aws/accounts/personal/us_east_1/applications/k3s

# Deploy tudo (cluster + bootstrap + ArgoCD apps)
bash deploy.sh deploy
```

O script executa 7 passos em sequencia:

| Step | O que faz                                                                    | Tempo estimado |
|------|------------------------------------------------------------------------------|----------------|
| 1/7  | `deploy_cluster` — Terragrunt apply no `cluster/` (EC2, RDS, NLB, IAM)     | ~8-12 min      |
| 2/7  | `wait_for_k3s` — Aguarda kubeconfig no SSM e JWKS no S3                    | ~3-5 min       |
| 3/7  | `setup_kubeconfig` — Baixa kubeconfig do SSM, merge em `~/.kube/config`    | ~10 seg        |
| 4/7  | `generate_values` — Extrai outputs do cluster, escreve nos values do ArgoCD | ~15 seg        |
| 5/7  | `deploy_helms` — Terragrunt apply no `helms/` (ArgoCD seed + secrets)       | ~2-3 min       |
| 6/7  | `deploy_root_app` — `kubectl apply` root-app + aguarda sync de todas apps  | ~5-10 min      |
| 7/7  | `verify` — Checa pods, services, certificates, DNS                          | ~10 seg        |

**Tempo total: ~20-30 minutos** (RDS e o gargalo principal).

### Deploy parcial

```bash
# Somente infraestrutura do cluster (sem workloads)
bash deploy.sh cluster-only

# Somente ArgoCD + workloads (cluster ja existe)
bash deploy.sh helms-only

# Regenerar values files (apos recriar cluster)
bash deploy.sh generate-values

# Verificar estado atual
bash deploy.sh verify
```

### Primeiro deploy — passo a passo manual

Se preferir executar passo a passo:

```bash
# 1. Carregar credenciais
export AWS_PROFILE=personal
export CLOUDFLARE_API_TOKEN="<seu-token>"

# 2. Deploy da infraestrutura
cd cluster/
terragrunt init && terragrunt apply

# 3. Aguardar kubeconfig no SSM (verificar manualmente)
aws ssm get-parameter --name "/k3s/kubeconfig" --with-decryption --region us-east-1

# 4. Configurar kubeconfig local
aws ssm get-parameter --name "/k3s/kubeconfig" --with-decryption \
  --region us-east-1 --query "Parameter.Value" --output text > ~/.kube/k3s
export KUBECONFIG=~/.kube/k3s
kubectl get nodes

# 5. Gerar values com outputs do cluster
cd ../
bash deploy.sh generate-values
# IMPORTANTE: commit e push dos values gerados antes do proximo passo
git add argocd/values/ && git commit -m "chore: generate argocd values" && git push

# 6. Bootstrap ArgoCD + secrets
cd helms/
export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
terragrunt init && terragrunt apply

# 7. Configurar acesso ao repo Git (se privado)
kubectl -n argocd create secret generic infra-iac-repo \
  --from-literal=url=https://github.com/Vinny1892/infra-iac.git \
  --from-literal=password=<PAT> \
  --from-literal=username=git \
  --from-literal=type=git
kubectl -n argocd label secret infra-iac-repo argocd.argoproj.io/secret-type=repository

# 8. Aplicar App of Apps
kubectl apply -f argocd/root-app.yaml

# 9. Acompanhar sync
watch kubectl get applications -n argocd
```

---

## Estrutura de Diretorios

```
k3s/
├── README.md                           # Este arquivo
├── deploy.sh                           # Script principal de deploy/destroy
├── pre-destroy.sh                      # Limpeza de recursos AWS orfaos
├── .kubeconfig                         # Gerado pelo deploy.sh (gitignored)
│
├── cluster/                            # Terraform — infraestrutura AWS
│   ├── terragrunt.hcl                  # Inclui o organism k3s/cluster
│   └── scripts/
│       └── init-master.tfpl            # User-data template do EC2
│
├── helms/                              # Terraform — bootstrap minimo
│   └── terragrunt.hcl                  # ArgoCD seed + namespaces + secrets
│
└── argocd/                             # GitOps — manifests gerenciados pelo ArgoCD
    ├── root-app.yaml                   # App of Apps (entrada principal)
    ├── apps/                           # ArgoCD Application definitions
    │   ├── cert-manager.yaml           # wave -5
    │   ├── cert-manager-config.yaml    # wave -4
    │   ├── pod-identity-webhook.yaml   # wave -3
    │   ├── aws-lb-controller.yaml      # wave -2
    │   ├── external-dns.yaml           # wave -1
    │   ├── traefik.yaml                # wave  0
    │   ├── argocd.yaml                 # wave  1
    │   └── whoami.yaml                 # wave  2
    ├── values/                         # Helm values (alguns com valores dinamicos)
    │   ├── cert-manager.yaml
    │   ├── aws-lb-controller.yaml      # contem role ARN e VPC ID (gerados)
    │   ├── external-dns.yaml
    │   ├── traefik.yaml
    │   └── argocd.yaml                 # contem role ARN (gerado)
    └── manifests/                      # Raw K8s YAML (nao-Helm)
        ├── cert-manager-config/
        │   └── cluster-issuer.yaml     # ClusterIssuer letsencrypt-prod
        ├── argocd/
        │   ├── certificate.yaml        # TLS cert argocd-k3s.vinny.dev.br
        │   └── ingressroute.yaml       # IngressRoute para ArgoCD UI
        └── whoami/
            ├── namespace.yaml
            ├── deployment.yaml          # traefik/whoami:v1.11.0
            ├── service.yaml
            ├── certificate.yaml         # TLS cert k3s.vinny.dev.br
            └── ingressroute.yaml        # IngressRoute /whoami
```

---

## Componentes

### Terraform — `cluster/`

Cria toda a infraestrutura AWS:

| Recurso                     | Descricao                                               |
|-----------------------------|---------------------------------------------------------|
| EC2 Auto Scaling Group      | K3s masters (t2.medium, Ubuntu)                         |
| Launch Template             | User-data com init-master.tfpl (instala K3s)            |
| RDS PostgreSQL              | Datastore do K3s (db.t3.micro, 20GB, managed password)  |
| Network Load Balancer       | Acesso externo ao K8s API (:6443)                       |
| Security Groups             | k3s_sg (cluster) + database_sg (RDS)                    |
| IAM Roles                   | Node role (SSM, S3, SecretsManager) + IRSA roles        |
| S3 Bucket                   | OIDC discovery endpoint (publico)                       |
| IAM OIDC Provider           | Federacao para IRSA                                     |
| SSM Parameter               | `/k3s/kubeconfig` (SecureString, gerado pelo master)    |

### Terraform — `helms/`

Bootstrap minimo antes do ArgoCD existir:

| Recurso                         | Descricao                                      |
|---------------------------------|------------------------------------------------|
| `helm_release.argocd`           | Instalacao seed do ArgoCD (config minima)       |
| `kubernetes_namespace.cert_manager` | Namespace cert-manager                      |
| `kubernetes_secret.cloudflare_api_token` | Token Cloudflare para cert-manager     |
| `kubernetes_namespace.external_dns` | Namespace external-dns                      |
| `kubernetes_secret.cloudflare_api_token_eds` | Token Cloudflare para ExternalDNS   |

### ArgoCD — `argocd/`

Apos o bootstrap, ArgoCD sincroniza automaticamente todos os workloads via App of Apps:

| Application          | Wave | Chart/Source               | Namespace     | Funcao                                  |
|----------------------|------|----------------------------|---------------|-----------------------------------------|
| cert-manager         | -5   | cert-manager v1.19.4       | cert-manager  | Emissao automatica de certificados TLS  |
| cert-manager-config  | -4   | Git manifests              | cert-manager  | ClusterIssuer letsencrypt-prod          |
| pod-identity-webhook | -3   | pod-identity-webhook 2.6.0 | kube-system   | IRSA para K3s (injeta AWS credentials)  |
| aws-lb-controller    | -2   | aws-lb-controller 3.1.0    | kube-system   | Provisiona NLBs para Services           |
| external-dns         | -1   | external-dns 1.20.0        | external-dns  | DNS automatico via Cloudflare           |
| traefik              |  0   | traefik 39.0.2             | traefik       | Ingress controller com NLB              |
| argocd               |  1   | argo-cd 9.4.5              | argocd        | Self-managed (assume config completa)   |
| whoami               |  2   | Git manifests              | whoami        | App de validacao (health check)         |

As **sync waves** garantem a ordem de deploy. ArgoCD espera cada wave ficar `Healthy` antes de prosseguir.

---

## Decisoes de Arquitetura

### Por que K3s em vez de EKS?

K3s e gratis — EKS cobra $0.10/hora (~$72/mes) so pelo control plane. Para um ambiente pessoal/teste, K3s em EC2 reduz custo drasticamente.

### Por que RDS como datastore do K3s?

K3s suporta etcd embarcado (multi-master) ou banco externo. RDS PostgreSQL foi escolhido porque:
- Nao precisa de quorum de etcd (pode rodar com 1 master e restaurar)
- Backups automaticos
- Managed password via Secrets Manager (sem plain-text no Terraform state)

### Por que ArgoCD App of Apps em vez de tudo no Terraform?

O `helms/terragrunt.hcl` original tinha 580 linhas gerenciando todos os Helm charts e recursos K8s via Terraform. Problemas:
- `kubernetes_manifest` valida schema no plan-time (CRDs precisam existir antes)
- Deploy em 2 stages com `-target` (fragil)
- Qualquer mudanca em um chart exige `terragrunt apply` manual
- Nao tem self-healing (drift detectado so no proximo plan)

Com ArgoCD App of Apps:
- `helms/terragrunt.hcl` ficou com ~80 linhas de codigo efetivo (bootstrap apenas)
- Charts e manifests sao YAML puro, facil de revisar e versionar
- Auto-sync com prune + selfHeal — ArgoCD corrige drift automaticamente
- Sync waves resolvem a ordem de deploy sem `-target` hacks
- Adicionar novas apps e criar um YAML em `argocd/apps/` e commitar

### Por que ExternalDNS em vez de Terraform Cloudflare modules?

Antes, os registros DNS eram criados pelo Terraform via `module "k3s_domain"` e `module "argocd_domain"`. Problemas:
- Terraform precisa ler o `data.kubernetes_service.traefik` para pegar o hostname do NLB
- Acoplamento forte: mudanca no Traefik exige `terragrunt apply` para atualizar DNS

Com ExternalDNS:
- Le a annotation `Host()` das IngressRoutes do Traefik
- Cria/atualiza CNAME automaticamente no Cloudflare
- Se uma IngressRoute e deletada, o registro DNS tambem e (policy: sync)
- Adicionar um dominio novo e so criar uma IngressRoute

### Por que IRSA customizado com Pod Identity Webhook?

K3s nao tem IRSA nativo (e feature do EKS). A solucao monta:
1. S3 bucket com OIDC discovery (`.well-known/openid-configuration` + JWKS)
2. IAM OIDC Provider apontando para o bucket
3. Pod Identity Webhook (mutating admission webhook) que injeta `AWS_ROLE_ARN` e `AWS_WEB_IDENTITY_TOKEN_FILE`

Isso permite que pods assumam IAM roles sem access keys hardcoded.

### Por que os secrets do Cloudflare sao criados no Terraform e nao no ArgoCD?

O token Cloudflare e sensivel e nao deve estar em YAML no Git. O Terraform cria os secrets nos namespaces `cert-manager` e `external-dns` **antes** do ArgoCD existir. Como nao tem labels `app.kubernetes.io/instance`, ArgoCD nao os detecta como "seus" e nao os pruna no sync.

### Por que ArgoCD seed + self-managed?

O ArgoCD e instalado em duas fases:
1. **Seed** (Terraform) — `helm_release.argocd` com config minima (ClusterIP, insecure mode, IRSA)
2. **Self-managed** (ArgoCD app wave 1) — ArgoCD Application que aponta para o proprio chart, com valores completos

Quando o ArgoCD app (wave 1) sincroniza, ele "assume" a gestao de si mesmo. A config completa inclui IngressRoute, Certificate TLS, e qualquer customizacao futura. Terraform fica apenas como bootstrap.

### Por que IMDSv2 enforced?

IMDSv1 e vulneravel a SSRF (Server-Side Request Forgery). Qualquer processo que consegue fazer HTTP requests pode obter as credenciais IAM da instancia. IMDSv2 requer um token de sessao (PUT request com hop limit), mitigando esse vetor.

---

## Operacoes do Dia-a-dia

### Adicionar uma nova aplicacao

1. Criar values file em `argocd/values/<app>.yaml` (se Helm chart)
2. Criar manifests em `argocd/manifests/<app>/` (se YAML puro)
3. Criar Application em `argocd/apps/<app>.yaml` com sync wave adequada
4. Commit + push para `main`
5. ArgoCD detecta e sincroniza automaticamente

### Atualizar versao de um chart

1. Editar `targetRevision` no arquivo `argocd/apps/<app>.yaml`
2. Commit + push
3. ArgoCD faz upgrade automaticamente

### Ver status das aplicacoes

```bash
kubectl get applications -n argocd
kubectl -n argocd get app <nome> -o yaml   # detalhes
```

### Acessar ArgoCD UI

```bash
# URL
echo "https://argocd-k3s.vinny.dev.br"

# Senha admin inicial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Regenerar values apos recriar cluster

Se o cluster foi destruido e recriado (novos ARNs/VPC ID):

```bash
bash deploy.sh generate-values
git add argocd/values/
git commit -m "chore: regenerate argocd values"
git push
```

---

## Troubleshooting

### Kubeconfig nao aparece no SSM

**Sintoma:** `wait_for_k3s` timeout apos 20 minutos.

**Causas possiveis:**
- RDS ainda inicializando (~5-10 min)
- K3s nao conseguiu conectar ao RDS (security group, DNS)
- User-data falhou

**Diagnostico:**
```bash
# Verificar logs da instancia
aws ssm start-session --target <instance-id>
sudo cat /var/log/cloud-init-output.log
sudo journalctl -u k3s
```

### IRSA nao funciona (pods sem permissao AWS)

**Sintoma:** AWS LB Controller ou ArgoCD com erro "AccessDenied".

**Causas possiveis:**
- JWKS nao foi uploaded para S3
- Pod Identity Webhook nao esta rodando
- ServiceAccount nao tem a annotation `eks.amazonaws.com/role-arn`

**Diagnostico:**
```bash
# Verificar JWKS no S3
aws s3 ls s3://k3s-oidc-<account-id>/openid/v1/jwks

# Verificar webhook
kubectl get pods -n kube-system -l app.kubernetes.io/name=amazon-eks-pod-identity-webhook

# Verificar annotations injetadas no pod
kubectl get pod <pod-name> -n <ns> -o yaml | grep -A5 AWS_
```

### Certificados TLS nao emitidos

**Sintoma:** `kubectl get certificates -A` mostra `False` no READY.

**Causas possiveis:**
- ClusterIssuer sem acesso ao Cloudflare (token invalido)
- DNS-01 challenge falhando

**Diagnostico:**
```bash
kubectl describe clusterissuer letsencrypt-prod
kubectl describe certificate -n argocd argocd-k3s-vinny-dev-br
kubectl get challenges -A
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
```

### DNS nao resolve

**Sintoma:** `dig k3s.vinny.dev.br` retorna vazio.

**Causas possiveis:**
- ExternalDNS sem acesso ao Cloudflare
- IngressRoute sem Host rule
- Traefik NLB ainda nao provisionado

**Diagnostico:**
```bash
# Verificar ExternalDNS logs
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns

# Verificar NLB do Traefik
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Verificar IngressRoutes
kubectl get ingressroute -A
```

### ArgoCD app stuck em "Progressing"

**Sintoma:** `kubectl get applications -n argocd` mostra uma app em Progressing por muito tempo.

**Causas possiveis:**
- Wave anterior nao completou (ex: cert-manager CRDs ainda nao existem)
- Helm chart com erro de valores
- Namespace nao existe

**Diagnostico:**
```bash
# Ver detalhes da app
kubectl -n argocd get app <nome> -o yaml | grep -A20 status

# Ver eventos
kubectl -n argocd get events --sort-by='.lastTimestamp'

# Forcar re-sync
kubectl -n argocd patch app <nome> -p '{"operation":{"sync":{"revision":"HEAD"}}}' --type merge
```

### Terraform plan mostra mudancas apos migracao

**Sintoma:** `cd helms/ && terragrunt plan` mostra recursos para destruir.

**Causa:** Recursos migrados para ArgoCD ainda estao no Terraform state.

**Solucao:**
```bash
cd helms/
terragrunt state rm helm_release.cert_manager
terragrunt state rm kubernetes_manifest.cluster_issuer
terragrunt state rm helm_release.pod_identity_webhook
terragrunt state rm helm_release.aws_lb_controller
terragrunt state rm helm_release.traefik
terragrunt state rm kubernetes_manifest.cert_argocd
terragrunt state rm kubernetes_manifest.cert_whoami
terragrunt state rm 'data.kubernetes_service.traefik'
terragrunt state rm 'module.k3s_domain'
terragrunt state rm 'module.argocd_domain'
terragrunt state rm kubernetes_manifest.argocd_ingressroute
terragrunt state rm kubernetes_namespace.whoami
terragrunt state rm kubernetes_deployment.whoami
terragrunt state rm kubernetes_service.whoami
terragrunt state rm kubernetes_manifest.whoami_ingressroute
```

---

## Destruicao

### Destroy completo

```bash
bash deploy.sh destroy
```

O script executa 4 passos:

1. **Deleta ArgoCD Applications** — `kubectl delete applications -n argocd --all` (remove Helm releases e recursos K8s)
2. **Pre-destroy cleanup** — `pre-destroy.sh` limpa recursos AWS orfaos (NLBs, Target Groups, Security Groups criados pelo LB Controller)
3. **Destroy helms** — `terragrunt destroy` no `helms/` (remove ArgoCD seed + secrets)
4. **Destroy cluster** — `terragrunt destroy` no `cluster/` (remove EC2, RDS, NLB, IAM, S3)

**A ordem e critica:** se o cluster for destruido antes dos NLBs, os recursos AWS ficam orfaos e precisam de limpeza manual.

### Destroy manual (se deploy.sh falhar)

```bash
# 1. Deletar apps ArgoCD
kubectl delete applications -n argocd --all --wait
sleep 30

# 2. Limpar recursos AWS orfaos
bash pre-destroy.sh

# 3. Destroy helms
cd helms/ && terragrunt destroy -auto-approve

# 4. Destroy cluster
cd ../cluster/ && terragrunt destroy -auto-approve
```

---

## Versoes

### Infraestrutura

| Componente       | Versao          | Nota                         |
|------------------|-----------------|------------------------------|
| Terraform        | >= 1.9.2        | Requerido                    |
| AWS Provider     | ~> 5.0          | hashicorp/aws                |
| TLS Provider     | ~> 4.0          | hashicorp/tls                |
| Helm Provider    | ~> 2.15         | hashicorp/helm               |
| Kubernetes Prov. | ~> 2.0          | hashicorp/kubernetes         |
| K3s              | v1.35.1+k3s1    | Instalado via get.k3s.io     |
| PostgreSQL (RDS) | 13              | db.t3.micro, 20GB            |

### Helm Charts (gerenciados pelo ArgoCD)

| Chart                          | Versao  | Repositorio                                    |
|--------------------------------|---------|------------------------------------------------|
| cert-manager                   | v1.19.4 | https://charts.jetstack.io                     |
| amazon-eks-pod-identity-webhook| 2.6.0   | https://jkroepke.github.io/helm-charts         |
| aws-load-balancer-controller   | 3.1.0   | https://aws.github.io/eks-charts               |
| external-dns                   | 1.20.0  | https://kubernetes-sigs.github.io/external-dns |
| traefik                        | 39.0.2  | https://traefik.github.io/charts               |
| argo-cd                        | 9.4.5   | https://argoproj.github.io/argo-helm           |

### Endpoints

| Servico | URL                              |
|---------|----------------------------------|
| Whoami  | https://k3s.vinny.dev.br/whoami  |
| ArgoCD  | https://argocd-k3s.vinny.dev.br  |
| K8s API | https://\<nlb\>:6443             |
