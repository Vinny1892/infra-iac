#!/bin/bash
set -euxo pipefail

exec > >(tee /var/log/openstack-aio-bootstrap.log) 2>&1

hostnamectl set-hostname "${hostname}"
timedatectl set-timezone "${timezone}" || true

dnf install -y \
  NetworkManager \
  git \
  jq \
  python3 \
  python3-pip \
  python3-libselinux \
  libffi-devel \
  gcc \
  make \
  qemu-kvm \
  libvirt \
  virt-install \
  libguestfs-tools \
  bridge-utils \
  tmux

systemctl enable --now NetworkManager
systemctl enable --now libvirtd || true

cat >/etc/modules-load.d/openstack-aio.conf <<'EOF'
br_netfilter
overlay
EOF

modprobe br_netfilter || true
modprobe overlay || true

cat >/etc/sysctl.d/99-openstack-aio.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system || true

mkdir -p /etc/openstack-aio
cat >/etc/openstack-aio/host.env <<EOF
ADMIN_USER=${admin_user}
PROVIDER_NIC_NAME=${provider_nic_name}
SSH_PORT=${ssh_port}
EOF

if [ "${ssh_port}" != "22" ]; then
  dnf install -y policycoreutils-python-utils firewalld
  systemctl enable --now firewalld
  sed -i "s/^#*Port .*/Port ${ssh_port}/" /etc/ssh/sshd_config
  semanage port -a -t ssh_port_t -p tcp ${ssh_port} 2>/dev/null || semanage port -m -t ssh_port_t -p tcp ${ssh_port}
  firewall-cmd --permanent --add-port=${ssh_port}/tcp
  firewall-cmd --reload
  systemctl restart sshd
fi
