#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$SCRIPT_DIR/cluster"
HELMS_DIR="$SCRIPT_DIR/helms"
ARGOCD_DIR="$SCRIPT_DIR/argocd"

# Carrega tokens e AWS profile via load_tf_vinny_root (definida no rc do shell).
# O .bashrc tem guarda de shell interativo, então usamos bash -i para extrair a função.
if [[ -z "${AWS_PROFILE:-}" ]] || [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  eval "$(bash -i -c 'declare -f load_tf_vinny_root' 2>/dev/null)"
  load_tf_vinny_root
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_prerequisites() {
  log "Checking prerequisites..."
  local missing=()

  command -v terragrunt >/dev/null 2>&1 || missing+=("terragrunt")
  command -v terraform >/dev/null 2>&1  || missing+=("terraform")
  command -v aws >/dev/null 2>&1        || missing+=("aws")
  command -v kubectl >/dev/null 2>&1    || missing+=("kubectl")
  command -v yq >/dev/null 2>&1         || missing+=("yq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing tools: ${missing[*]}"
    exit 1
  fi

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    warn "CLOUDFLARE_API_TOKEN not set. Secrets bootstrap will fail."
  fi

  log "All prerequisites met."
}

deploy_cluster() {
  log "=== Step 1/7: Deploying K3s cluster infrastructure ==="
  cd "$CLUSTER_DIR"

  terragrunt init
  terragrunt apply -auto-approve

  log "Cluster infrastructure deployed."
}

wait_for_k3s() {
  log "=== Step 2/7: Waiting for K3s bootstrap ==="

  local max_attempts=120
  local attempt=0

  log "Waiting for kubeconfig in SSM Parameter Store..."
  while [[ $attempt -lt $max_attempts ]]; do
    if aws ssm get-parameter \
        --name "/k3s/kubeconfig" \
        --with-decryption \
        --region us-east-1 \
        --query "Parameter.Value" \
        --output text > /dev/null 2>&1; then
      log "Kubeconfig found in SSM."
      break
    fi

    attempt=$((attempt + 1))
    echo -n "."
    sleep 10
  done

  if [[ $attempt -ge $max_attempts ]]; then
    err "Timeout waiting for kubeconfig in SSM after $((max_attempts * 10))s. (RDS leva ~5-10min para ficar pronto)"
    err "Check EC2 instance user_data logs: /var/log/cloud-init-output.log"
    exit 1
  fi

  log "Waiting for JWKS in S3..."
  attempt=0
  local bucket
  bucket=$(cd "$CLUSTER_DIR" && terragrunt output -raw oidc_provider_url 2>/dev/null | sed 's|https://||' | sed 's|\.s3.*||')

  while [[ $attempt -lt $max_attempts ]]; do
    if aws s3 ls "s3://${bucket}/openid/v1/jwks" --region us-east-1 > /dev/null 2>&1; then
      log "JWKS found in S3."
      break
    fi

    attempt=$((attempt + 1))
    echo -n "."
    sleep 10
  done

  if [[ $attempt -ge $max_attempts ]]; then
    warn "Timeout waiting for JWKS in S3. IRSA may not work until JWKS is uploaded."
  fi
}

setup_kubeconfig() {
  log "=== Step 3/7: Setting up local kubeconfig ==="

  local kubeconfig_path="$SCRIPT_DIR/.kubeconfig"

  aws ssm get-parameter \
    --name "/k3s/kubeconfig" \
    --with-decryption \
    --region us-east-1 \
    --query "Parameter.Value" \
    --output text > "$kubeconfig_path"

  chmod 600 "$kubeconfig_path"

  # Garante que o contexto seja k3s-aws independente do que veio do SSM
  if kubectl --kubeconfig "$kubeconfig_path" config get-contexts default &>/dev/null; then
    kubectl --kubeconfig "$kubeconfig_path" config rename-context default k3s-aws
  fi

  export KUBECONFIG="$kubeconfig_path"

  log "Testing cluster connectivity..."
  if kubectl get nodes --request-timeout=10s; then
    log "Cluster is reachable."
  else
    err "Cannot reach cluster. Check NLB and security groups."
    exit 1
  fi

  # Merge into ~/.kube/config
  local kube_dir="$HOME/.kube"
  local kube_config="$kube_dir/config"
  mkdir -p "$kube_dir"

  if [[ -f "$kube_config" ]]; then
    log "Merging kubeconfig into $kube_config..."
    local backup="$kube_config.bak.$(date +%s)"
    cp "$kube_config" "$backup"
    log "Backup saved at $backup"
    KUBECONFIG="$kube_config:$kubeconfig_path" kubectl config view --flatten > "$kube_dir/config_merged"
    mv "$kube_dir/config_merged" "$kube_config"
  else
    log "Creating $kube_config..."
    cp "$kubeconfig_path" "$kube_config"
  fi

  chmod 600 "$kube_config"
  export KUBECONFIG="$kube_config"
  kubectl config use-context k3s-aws
  log "Kubeconfig merged into $kube_config — contexto ativo: k3s-aws"
}

generate_values() {
  log "=== Step 4/7: Generating ArgoCD values from cluster outputs ==="
  cd "$CLUSTER_DIR"

  local outputs
  outputs=$(terragrunt output -json)

  local aws_lb_role_arn vpc_id argocd_role_arn
  aws_lb_role_arn=$(echo "$outputs" | jq -r '.aws_lb_controller_role_arn.value')
  argocd_role_arn=$(echo "$outputs" | jq -r '.argocd_role_arn.value')
  vpc_id=$(echo "$outputs" | jq -r '.vpc_id.value')

  log "aws_lb_controller_role_arn: $aws_lb_role_arn"
  log "argocd_role_arn:            $argocd_role_arn"
  log "vpc_id:                     $vpc_id"

  # Update aws-lb-controller values
  local lb_values="$ARGOCD_DIR/values/aws-lb-controller.yaml"
  yq -Yi ".serviceAccount.annotations.\"eks.amazonaws.com/role-arn\" = \"$aws_lb_role_arn\"" "$lb_values"
  yq -Yi ".vpcId = \"$vpc_id\"" "$lb_values"
  log "Updated $lb_values"

  # Update argocd values
  local argocd_values="$ARGOCD_DIR/values/argocd.yaml"
  yq -Yi ".server.serviceAccount.annotations.\"eks.amazonaws.com/role-arn\" = \"$argocd_role_arn\"" "$argocd_values"
  log "Updated $argocd_values"

  log "Values generated. Commit and push these files before deploying ArgoCD apps."
}

patch_ingress_routes() {
  log "=== Step 4.5/7: Patching IngressRoute manifests with NLB hostname ==="

  local max_attempts=30
  local attempt=0
  local traefik_lb=""

  log "Waiting for Traefik NLB assignment..."
  while [[ $attempt -lt $max_attempts ]]; do
    traefik_lb=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -n "$traefik_lb" ]]; then
      log "Traefik NLB found: $traefik_lb"
      break
    fi
    attempt=$((attempt + 1))
    echo -n "."
    sleep 10
  done

  if [[ -z "$traefik_lb" ]]; then
    err "Timeout waiting for Traefik NLB. Cannot patch IngressRoutes."
    return 1
  fi

  # Replace placeholders in manifests
  # Usamos sed para substituir ${TRAEFIK_NLB_HOSTNAME} pelo valor real nos arquivos
  find "$ARGOCD_DIR/manifests" -name "ingressroute.yaml" -exec sed -i "s/\${TRAEFIK_NLB_HOSTNAME}/$traefik_lb/g" {} +

  log "Manifests patched with current NLB hostname."
}

deploy_helms() {
  log "=== Step 5/7: Deploying ArgoCD seed + secrets bootstrap ==="
  cd "$HELMS_DIR"

  export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"

  terragrunt init
  terragrunt apply -auto-approve

  log "ArgoCD seed + secrets deployed."
}

deploy_root_app() {
  log "=== Step 6/7: Deploying ArgoCD App of Apps ==="

  kubectl apply --validate=false -f "$ARGOCD_DIR/root-app.yaml"

  log "Root app applied. Waiting for ArgoCD to sync all applications..."

  wait_for_sync
}

wait_for_sync() {
  local max_attempts=60
  local attempt=0
  local expected_apps=8

  while [[ $attempt -lt $max_attempts ]]; do
    local synced_healthy
    synced_healthy=$(kubectl get applications -n argocd \
      --no-headers 2>/dev/null \
      | grep -c "Synced.*Healthy" || true)

    local total
    total=$(kubectl get applications -n argocd \
      --no-headers 2>/dev/null \
      | wc -l | tr -d ' ')

    log "Applications synced/healthy: $synced_healthy / $total (expecting $expected_apps + root)"

    # expected_apps child apps + 1 root app = expected_apps + 1
    if [[ $synced_healthy -ge $((expected_apps + 1)) ]]; then
      log "All applications are Synced and Healthy!"
      return 0
    fi

    # Show status of non-healthy apps
    kubectl get applications -n argocd --no-headers 2>/dev/null \
      | grep -v "Synced.*Healthy" || true

    attempt=$((attempt + 1))
    sleep 15
  done

  warn "Timeout waiting for all apps to sync. Check: kubectl -n argocd get applications"
  kubectl get applications -n argocd 2>/dev/null || true
  return 1
}

verify() {
  log "=== Step 7/7: Verification ==="

  log "Checking ArgoCD Applications..."
  kubectl get applications -n argocd

  log "Checking AWS Load Balancer Controller..."
  kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers

  log "Checking Traefik..."
  kubectl -n traefik get pods --no-headers

  log "Checking ArgoCD..."
  kubectl -n argocd get pods --no-headers

  log "Checking ExternalDNS..."
  kubectl -n external-dns get pods --no-headers

  log "Checking Traefik NLB service..."
  local traefik_lb
  traefik_lb=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

  if [[ -n "$traefik_lb" ]]; then
    log "Traefik NLB: $traefik_lb"
  else
    warn "Traefik NLB not yet assigned. It may take a few minutes."
  fi

  log "Checking Certificates..."
  kubectl get certificates -A --no-headers 2>/dev/null || warn "No certificates found yet."

  log "Checking IngressRoutes..."
  kubectl get ingressroute -A --no-headers 2>/dev/null || warn "IngressRoute CRD not found yet."

  log "Checking DNS..."
  if command -v dig >/dev/null 2>&1; then
    dig +short k3s.vinny.dev.br || warn "DNS not yet propagated for k3s.vinny.dev.br"
  fi

  echo ""
  log "============================================"
  log "  Deployment complete!"
  log "============================================"
  echo ""
  log "Endpoints:"
  log "  Whoami:  https://k3s.vinny.dev.br/whoami"
  log "  ArgoCD:  https://argocd-k3s.vinny.dev.br"
  echo ""
  log "ArgoCD initial admin password:"
  log "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
  echo ""
  log "Kubeconfig merged into ~/.kube/config"
  log "  kubectl config get-contexts"
}

# =============================================================================
# Main
# =============================================================================

main() {
  local action="${1:-deploy}"

  case "$action" in
    deploy)
      check_prerequisites
      deploy_cluster
      wait_for_k3s
      setup_kubeconfig
      generate_values
      deploy_helms
      deploy_root_app
      patch_ingress_routes
      verify
      ;;
    cluster-only)
      check_prerequisites
      deploy_cluster
      wait_for_k3s
      setup_kubeconfig
      ;;
    helms-only)
      check_prerequisites
      setup_kubeconfig
      deploy_helms
      deploy_root_app
      verify
      ;;
    generate-values)
      check_prerequisites
      generate_values
      ;;
    verify)
      setup_kubeconfig
      verify
      ;;
    destroy)
      check_prerequisites
      warn "=== Step 1/4: Deleting ArgoCD Applications ==="
      # kubectl delete applications -n argocd --all --wait=true 2>/dev/null || warn "No ArgoCD applications found or cluster unreachable."
      warn "=== Step 2/4: Pre-destroy cleanup (K8s-spawned AWS resources) ==="
      "$SCRIPT_DIR/pre-destroy.sh"
      warn "=== Step 3/4: Destroying Helm releases (ArgoCD seed + secrets) ==="
      cd "$HELMS_DIR"  && terragrunt destroy -auto-approve || true
      warn "=== Step 4/4: Destroying cluster infrastructure ==="
      cd "$CLUSTER_DIR" && terragrunt destroy -auto-approve
      log "Destroyed."
      ;;
    *)
      echo "Usage: $0 {deploy|cluster-only|helms-only|generate-values|verify|destroy}"
      exit 1
      ;;
  esac
  
}

main "$@"
