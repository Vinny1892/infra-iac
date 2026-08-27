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

# O uninstall do K3s NAO acontece aqui. Ele derruba o API server, e o
# `terragrunt destroy` dos helm releases — que roda depois deste script — precisa
# do cluster vivo para remover os releases. Com o uninstall aqui, aquele destroy
# falhava sempre com "cluster unreachable" e deixava os recursos orfaos no state.
# O uninstall foi movido para deploy.sh, apos o destroy dos helms.

echo "==> Pre-destroy cleanup complete."
