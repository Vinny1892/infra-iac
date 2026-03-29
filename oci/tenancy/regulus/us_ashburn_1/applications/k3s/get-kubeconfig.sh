#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_USER="ubuntu"
KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"

VM_IP=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && terragrunt output -raw instance_public_ip 2>/dev/null)

echo "VM IP: $VM_IP"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "$SSH_USER@$VM_IP:/etc/rancher/k3s/k3s.yaml" /tmp/k3s-oci-raw.yaml
sed "s/127.0.0.1/$VM_IP/g" /tmp/k3s-oci-raw.yaml > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"
echo "Kubeconfig salvo em $KUBECONFIG_PATH"
kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes
