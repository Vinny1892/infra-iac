#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="22"
SSH_USER="ubuntu"
KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"
KUBECTL="kubectl --kubeconfig $KUBECONFIG_PATH"

# Get VM IP dynamically from Terraform state
VM_IP=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && terragrunt output -raw instance_public_ip 2>/dev/null) || true

echo "==> Deleting ArgoCD applications..."
$KUBECTL delete applications -n argocd --all --timeout=120s 2>/dev/null || echo "No ArgoCD apps found or already deleted."

echo "==> Waiting for ArgoCD to clean up resources..."
sleep 30

echo "==> Deleting PVCs across all namespaces..."
$KUBECTL delete pvc --all-namespaces --all --timeout=120s 2>/dev/null || echo "No PVCs found."

if [ -n "${VM_IP:-}" ]; then
  echo "==> Uninstalling K3s on VM ($VM_IP)..."
  ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$VM_IP" \
    "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null || echo "K3s not installed or already removed."
else
  echo "==> Skipping K3s uninstall (VM IP not available)."
fi

echo "==> Pre-destroy cleanup complete."
