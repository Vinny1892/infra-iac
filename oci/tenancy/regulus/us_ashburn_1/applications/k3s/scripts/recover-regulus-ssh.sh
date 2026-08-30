#!/usr/bin/env bash
set -euo pipefail

DEVICE="/dev/oracleoci/oraclevdb"
MOUNT_POINT="/mnt/regulus-recovery"

if [ -z "${REGULUS_SSH_PUBLIC_KEY_B64:-}" ]; then
  echo "ERROR: REGULUS_SSH_PUBLIC_KEY_B64 nao foi informado."
  exit 1
fi

for attempt in $(seq 1 30); do
  if [ -b "$DEVICE" ]; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "ERROR: boot volume da Regulus nao apareceu como $DEVICE."
    exit 1
  fi
  sleep 5
done

root_partition=$(lsblk -nrpo NAME,TYPE "$DEVICE" | awk '$2 == "part" { print $1; exit }')
if [ -z "$root_partition" ]; then
  echo "ERROR: particao raiz nao encontrada em $DEVICE."
  exit 1
fi

install -d -m 700 "$MOUNT_POINT"
mount "$root_partition" "$MOUNT_POINT"
trap 'umount "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT

ssh_dir="$MOUNT_POINT/home/ubuntu/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
public_key=$(printf '%s' "$REGULUS_SSH_PUBLIC_KEY_B64" | base64 --decode)

install -d -m 700 "$ssh_dir"
touch "$authorized_keys"
if ! grep -qxF "$public_key" "$authorized_keys"; then
  printf '%s\n' "$public_key" >> "$authorized_keys"
fi
chown --reference="$MOUNT_POINT/home/ubuntu" "$ssh_dir" "$authorized_keys"
chmod 600 "$authorized_keys"
sync
umount "$MOUNT_POINT"
trap - EXIT

echo "Chave SSH da Regulus recuperada."
