#!/bin/bash
# K3s single-node install script for OCI Ubuntu 24.04 (ARM)
# Usage: sudo bash install-k3s.sh <PUBLIC_IP> [DNS_NAME]
set -euo pipefail
exec > >(tee /var/log/k3s-install.log) 2>&1

PUBLIC_IP="${1:?Usage: $0 <PUBLIC_IP> [DNS_NAME]}"
DNS_NAME="${2:-}"
K3S_VERSION="v1.33.1+k3s1"

echo "==> Installing Longhorn prerequisites"
apt-get update -y
apt-get install -y open-iscsi nfs-common
systemctl enable --now iscsid

echo "==> Abrindo portas no iptables (OCI Ubuntu bloqueia por default)"
iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
iptables -I INPUT -p udp --dport 8472 -j ACCEPT
apt-get install -y iptables-persistent -q
netfilter-persistent save

echo "==> K3s ${K3S_VERSION} instalando..."
TLS_SANS="--tls-san ${PUBLIC_IP}"
if [[ -n "${DNS_NAME}" ]]; then
  TLS_SANS="${TLS_SANS} --tls-san ${DNS_NAME}"
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
  --write-kubeconfig-mode 644 \
  --disable=traefik \
  --disable=servicelb \
  ${TLS_SANS}

echo "==> Aguardando K3s ficar Ready..."
until /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  echo "  ainda aguardando..."
  sleep 5
done

echo "==> K3s pronto"
/usr/local/bin/kubectl get nodes
