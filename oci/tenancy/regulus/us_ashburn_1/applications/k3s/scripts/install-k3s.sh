#!/bin/bash
# K3s single-node install script for OCI Ubuntu 24.04 (ARM)
# Usage: sudo bash install-k3s.sh <PUBLIC_IP> [DNS_NAME]
set -euo pipefail
exec > >(tee /var/log/k3s-install.log) 2>&1

PUBLIC_IP="${1:?Usage: $0 <PUBLIC_IP> [DNS_NAME]}"
DNS_NAME="${2:-}"
K3S_VERSION="v1.36.4+k3s1"

# Quem disputa o lock do apt no primeiro boot NAO e o apt-daily: e o snap do
# Oracle Cloud Agent, que roda `/bin/apt update` sozinho quando a instancia sobe
# (no journal: "snap_daemon ... COMMAND=/bin/apt update"). Ele nao esta sob nosso
# controle, e `DPkg::Lock::Timeout` nao cobre o lock de /var/lib/apt/lists, que e
# o disputado pelo `apt-get update`. A saida confiavel e insistir.
systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

apt_retry() {
  local desc="$1"; shift
  local i
  for i in $(seq 1 60); do
    if "$@"; then
      return 0
    fi
    echo "  apt ocupado em '$desc' (tentativa $i/60); aguardando 10s..."
    sleep 10
  done
  echo "ERRO: '$desc' nao concluiu apos 10 min aguardando o lock do apt."
  exit 1
}

echo "==> Installing Longhorn prerequisites"
apt_retry "update" apt-get -o DPkg::Lock::Timeout=600 update -y
apt_retry "open-iscsi nfs-common" apt-get -o DPkg::Lock::Timeout=600 install -y open-iscsi nfs-common
systemctl enable --now iscsid

echo "==> Abrindo portas no iptables (OCI Ubuntu bloqueia por default)"
iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
iptables -I INPUT -p udp --dport 8472 -j ACCEPT
apt_retry "iptables-persistent" apt-get -o DPkg::Lock::Timeout=600 install -y iptables-persistent -q
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
