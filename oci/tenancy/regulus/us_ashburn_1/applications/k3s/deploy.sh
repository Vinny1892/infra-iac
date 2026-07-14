#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"  # us_ashburn_1/

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="22"
SSH_USER="ubuntu"
KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"

preflight_check() {
  if ! op vault list &>/dev/null; then
    echo "ERROR: 1Password CLI nao esta autenticado."
    echo "  Exporte OP_SERVICE_ACCOUNT_TOKEN ou rode: eval \$(op signin)"
    exit 1
  fi
}

get_vm_ip() {
  terragrunt output -raw instance_public_ip 2>/dev/null
}

provision_vm() {
  echo "==> Provisionando VM (user_data instala K3s automaticamente)..."
  cd "$OCI_UNIT_DIR/network/vcn"
  terragrunt apply --auto-approve
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  terragrunt apply --auto-approve
}

wait_for_k3s() {
  local vm_ip
  vm_ip=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && get_vm_ip)
  local SSH="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no $SSH_USER@$vm_ip"

  echo "==> VM IP: $vm_ip — aguardando K3s ficar Ready (cloud-init)..." >&2
  local retries=60
  for i in $(seq 1 $retries); do
    if $SSH "kubectl get nodes 2>/dev/null | grep -q ' Ready'" 2>/dev/null; then
      echo "K3s pronto." >&2
      echo "$vm_ip"
      return 0
    fi
    echo "  Tentativa $i/$retries — aguardando 15s..." >&2
    sleep 15
  done
  echo "ERROR: K3s nao ficou Ready." >&2
  exit 1
}

fetch_kubeconfig() {
  local vm_ip="$1"
  echo "==> Buscando kubeconfig da VM..."
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"

  local retries=20
  local success=false
  for i in $(seq 1 $retries); do
    if ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$vm_ip" "cat /etc/rancher/k3s/k3s.yaml" > /tmp/k3s-oci-raw.yaml 2>/dev/null; then
      success=true
      break
    fi
    echo "  Tentativa $i/$retries - aguardando SSH e K3s ficarem disponíveis..."
    sleep 15
  done

  if [ "$success" = false ]; then
    echo "ERROR: Não foi possível conectar via SSH após $retries tentativas"
    exit 1
  fi

  sed "s/127.0.0.1/$vm_ip/g" /tmp/k3s-oci-raw.yaml > "$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"
  echo "Kubeconfig salvo em $KUBECONFIG_PATH"
}

# Clean up stuck Terraform state locks and pending Helm releases
cleanup_helms_state() {
  echo "==> Limpando state locks e helm releases pendentes..."
  cd "$SCRIPT_DIR/helms"

  # Force-unlock any stuck state lock
  local lock_id
  lock_id=$(K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt plan 2>&1 | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1) || true
  if [ -n "${lock_id:-}" ]; then
    echo "  Removendo state lock $lock_id..."
    terragrunt force-unlock -force "$lock_id" 2>/dev/null || true
  fi

  # Clean up pending-install/pending-upgrade helm releases
  for ns in metallb-system cert-manager longhorn-system argocd; do
    kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$ns" get secret -l owner=helm -o jsonpath='{range .items[?(@.metadata.labels.status!="deployed")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | while read -r secret; do
      if [ -n "$secret" ]; then
        echo "  Removendo helm secret pendente: $ns/$secret"
        kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$ns" delete secret "$secret" 2>/dev/null || true
      fi
    done
  done
}

deploy_helms() {
  echo "==> Deploy helm releases (cert-manager, longhorn, argocd)..."
  cleanup_helms_state
  cd "$SCRIPT_DIR/helms"
  K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt apply --auto-approve
}

deploy_root_app() {
  echo "==> Aplicando ArgoCD root app-of-apps..."
  kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f "$SCRIPT_DIR/argocd/root-app.yaml"
}

verify() {
  echo "==> Verificando cluster..."
  echo "--- Nodes ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes
  echo "--- Storage classes ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get sc
  echo "--- ArgoCD apps ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get applications -n argocd 2>/dev/null || echo "(ArgoCD ainda nao sincronizou)"
  echo "--- Pods ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A
}

destroy() {
  echo "==> Pre-destroy cleanup..."
  bash "$SCRIPT_DIR/pre-destroy.sh"

  echo "==> Destruindo helm releases..."
  cd "$SCRIPT_DIR/helms"
  # Force-unlock before destroy too
  local lock_id
  lock_id=$(K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt plan 2>&1 | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1) || true
  if [ -n "${lock_id:-}" ]; then
    terragrunt force-unlock -force "$lock_id" 2>/dev/null || true
  fi
  K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt destroy --auto-approve || true

  echo "==> Destruindo VM..."
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  terragrunt destroy --auto-approve || true
}

MODE="${1:-deploy}"

case "$MODE" in
  deploy)
    preflight_check
    provision_vm
    VM_IP=$(wait_for_k3s)
    fetch_kubeconfig "$VM_IP"
    deploy_helms
    deploy_root_app
    verify
    ;;
  helms-only)
    preflight_check
    deploy_helms
    deploy_root_app
    ;;
  verify)
    verify
    ;;
  destroy)
    preflight_check
    destroy
    ;;
  *)
    echo "Usage: $0 [deploy|helms-only|verify|destroy]"
    exit 1
    ;;
esac
