#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$SCRIPT_DIR/cluster"
HELMS_DIR="$SCRIPT_DIR/helms"

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

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing tools: ${missing[*]}"
    exit 1
  fi

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    warn "CLOUDFLARE_API_TOKEN not set. Cloudflare DNS record will fail."
  fi

  log "All prerequisites met."
}

deploy_cluster() {
  log "=== Step 1/5: Deploying K3s cluster infrastructure ==="
  cd "$CLUSTER_DIR"

  terragrunt init
  terragrunt apply -auto-approve

  log "Cluster infrastructure deployed."
}

wait_for_k3s() {
  log "=== Step 2/5: Waiting for K3s bootstrap ==="

  local max_attempts=60
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
    err "Timeout waiting for kubeconfig in SSM after $((max_attempts * 10))s."
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
  log "=== Step 3/5: Setting up local kubeconfig ==="

  local kubeconfig_path="$SCRIPT_DIR/.kubeconfig"

  aws ssm get-parameter \
    --name "/k3s/kubeconfig" \
    --with-decryption \
    --region us-east-1 \
    --query "Parameter.Value" \
    --output text > "$kubeconfig_path"

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
  log "Kubeconfig merged into $kube_config"
}

deploy_helms() {
  log "=== Step 4/5: Deploying Helm releases (LB Controller, Traefik, ArgoCD) ==="
  cd "$HELMS_DIR"

  # Reusa o token Cloudflare já carregado no ambiente
  export TF_VAR_cloudflare_api_token="${CLOUDFLARE_API_TOKEN:-}"

  terragrunt init
  terragrunt apply -auto-approve

  log "Helm releases deployed."
}

verify() {
  log "=== Step 5/5: Verification ==="

  log "Checking AWS Load Balancer Controller..."
  kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers

  log "Checking Traefik..."
  kubectl -n traefik get pods --no-headers

  log "Checking ArgoCD..."
  kubectl -n argocd get pods --no-headers

  log "Checking Traefik NLB service..."
  local traefik_lb
  traefik_lb=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

  if [[ -n "$traefik_lb" ]]; then
    log "Traefik NLB: $traefik_lb"
  else
    warn "Traefik NLB not yet assigned. It may take a few minutes."
  fi

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
      deploy_helms
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
      verify
      ;;
    verify)
      setup_kubeconfig
      verify
      ;;
    destroy)
      warn "Destroying in reverse order..."
      cd "$HELMS_DIR"  && terragrunt destroy -auto-approve || true
      cd "$CLUSTER_DIR" && terragrunt destroy -auto-approve
      log "Destroyed."
      ;;
    *)
      echo "Usage: $0 {deploy|cluster-only|helms-only|verify|destroy}"
      exit 1
      ;;
  esac
}

main "$@"
