#!/usr/bin/env bash
set -euo pipefail

VM_IP="129.213.131.226"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="22"
SSH_USER="ubuntu"
KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"
KUBECTL="kubectl --kubeconfig $KUBECONFIG_PATH"

echo "==> Deleting ArgoCD applications..."
$KUBECTL delete applications -n argocd --all --timeout=120s 2>/dev/null || echo "No ArgoCD apps found or already deleted."

echo "==> Waiting for ArgoCD to clean up resources..."
sleep 30

echo "==> Deleting PVCs across all namespaces..."
$KUBECTL delete pvc --all-namespaces --all --timeout=120s 2>/dev/null || echo "No PVCs found."

echo "==> Uninstalling K3s on VM..."
ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no "ubuntu@$VM_IP" \
  "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null || echo "K3s not installed or already removed."

echo "==> Pre-destroy cleanup complete."
