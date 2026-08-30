#!/usr/bin/env bash
set -euo pipefail

DEVICE="/dev/oracleoci/oraclevdb"
LONGHORN_DIR="/var/lib/longhorn"
TEMP_MOUNT="/mnt/longhorn-data"

install_ssh_key() {
  if [ -z "${REGULUS_SSH_PUBLIC_KEY_B64:-}" ]; then
    echo "ERROR: REGULUS_SSH_PUBLIC_KEY_B64 nao foi informado."
    exit 1
  fi

  local public_key
  public_key=$(printf '%s' "$REGULUS_SSH_PUBLIC_KEY_B64" | base64 --decode)

  install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
  touch /home/ubuntu/.ssh/authorized_keys
  if ! grep -qxF "$public_key" /home/ubuntu/.ssh/authorized_keys; then
    printf '%s\n' "$public_key" >> /home/ubuntu/.ssh/authorized_keys
  fi
  chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
  chmod 600 /home/ubuntu/.ssh/authorized_keys
}

wait_for_device() {
  for attempt in $(seq 1 60); do
    if [ -b "$DEVICE" ]; then
      return 0
    fi
    echo "Aguardando $DEVICE ($attempt/60)..."
    sleep 5
  done

  echo "ERROR: block volume nao apareceu como $DEVICE."
  exit 1
}

configure_longhorn_volume() {
  wait_for_device

  if ! blkid "$DEVICE" >/dev/null 2>&1; then
    mkfs.ext4 -F -L longhorn-data "$DEVICE"
  fi

  local volume_uuid
  volume_uuid=$(blkid -s UUID -o value "$DEVICE")

  if findmnt -rn -S "UUID=$volume_uuid" -T "$LONGHORN_DIR" >/dev/null 2>&1; then
    echo "$DEVICE ja esta montado em $LONGHORN_DIR."
    return 0
  fi

  install -d -m 755 "$TEMP_MOUNT" "$LONGHORN_DIR"
  mount "$DEVICE" "$TEMP_MOUNT"

  # O Run Command roda fora do K3s, então pode parar o serviço para obter uma
  # cópia consistente dos volumes antes de trocar o mount point.
  until systemctl is-active --quiet k3s; do
    echo "Aguardando o K3s ficar ativo antes da migracao..."
    sleep 10
  done
  systemctl stop k3s
  trap 'systemctl start k3s >/dev/null 2>&1 || true' EXIT
  cp -a "$LONGHORN_DIR/." "$TEMP_MOUNT/"
  sync
  umount "$TEMP_MOUNT"

  sed -i '\|[[:space:]]/var/lib/longhorn[[:space:]]|d' /etc/fstab
  printf 'UUID=%s %s ext4 defaults,_netdev,nofail 0 2\n' \
    "$volume_uuid" "$LONGHORN_DIR" >> /etc/fstab
  mount "$LONGHORN_DIR"
  systemctl start k3s
  trap - EXIT
}

install_ssh_key
configure_longhorn_volume

findmnt "$LONGHORN_DIR"
