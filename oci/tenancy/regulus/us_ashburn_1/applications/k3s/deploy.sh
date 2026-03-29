#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"  # us_ashburn_1/

DNS_NAME="k3s.vinny.dev.br"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="22"
SSH_USER="ubuntu"
KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"

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

  echo "==> VM IP: $vm_ip — aguardando K3s ficar Ready (cloud-init)..."
  local retries=60
  for i in $(seq 1 $retries); do
    if $SSH "kubectl get nodes 2>/dev/null | grep -q ' Ready'" 2>/dev/null; then
      echo "K3s pronto."
      echo "$vm_ip"
      return 0
    fi
    echo "  Tentativa $i/$retries — aguardando 15s..."
    sleep 15
  done
  echo "ERROR: K3s nao ficou Ready."
  exit 1
}

fetch_kubeconfig() {
  local vm_ip="$1"
  echo "==> Buscando kubeconfig da VM..."
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no \
    "$SSH_USER@$vm_ip:/etc/rancher/k3s/k3s.yaml" /tmp/k3s-oci-raw.yaml
  sed "s/127.0.0.1/$vm_ip/g" /tmp/k3s-oci-raw.yaml > "$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"
  echo "Kubeconfig salvo em $KUBECONFIG_PATH"
}

deploy_dns() {
  echo "==> Aplicando DNS Cloudflare..."
  cd "$SCRIPT_DIR/dns"
  terragrunt apply --auto-approve
}

deploy_helms() {
  echo "==> Deploy helm releases (cert-manager, longhorn, argocd)..."
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
  K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt destroy --auto-approve || true

  echo "==> Destruindo DNS..."
  cd "$SCRIPT_DIR/dns"
  terragrunt destroy --auto-approve || true

  echo "==> Destruindo VM..."
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  terragrunt destroy --auto-approve || true
}

MODE="${1:-deploy}"

case "$MODE" in
  deploy)
    provision_vm
    VM_IP=$(wait_for_k3s)
    fetch_kubeconfig "$VM_IP"
    deploy_dns
    deploy_helms
    deploy_root_app
    verify
    ;;
  helms-only)
    deploy_helms
    deploy_root_app
    ;;
  verify)
    verify
    ;;
  destroy)
    destroy
    ;;
  *)
    echo "Usage: $0 [deploy|helms-only|verify|destroy]"
    exit 1
    ;;
esac
