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
  # Idempotente: uma execucao anterior interrompida depois do mount deixa o
  # dispositivo montado no TEMP_MOUNT, e `mount` de novo falharia com "already
  # mounted" — derrubando o script pelo set -e.
  if ! findmnt -rn -S "UUID=$volume_uuid" -T "$TEMP_MOUNT" >/dev/null 2>&1; then
    mount "$DEVICE" "$TEMP_MOUNT"
  else
    echo "$DEVICE ja estava montado em $TEMP_MOUNT (execucao anterior)."
  fi

  # Se houver K3s rodando, ele para para a copia sair consistente. Se nao
  # houver, nao ha o que parar nem o que migrar.
  #
  # A versao anterior fazia `until systemctl is-active --quiet k3s` sem limite,
  # e isso escondia duas suposicoes que deixaram de valer com o cluster em dois
  # nodes:
  #
  #   1. que este script roda sempre no server. Na danebola ele roda ANTES do
  #      join — o mount tem de existir antes do Longhorn — entao esperava por um
  #      k3s que ainda nao existia, para sempre. Travou o deploy de 04/09/2026.
  #   2. que o servico se chama `k3s`. No agent ele e `k3s-agent`, entao nem
  #      depois do join a condicao bateria.
  local k3s_unit=""
  if systemctl is-active --quiet k3s; then
    k3s_unit="k3s"
  elif systemctl is-active --quiet k3s-agent; then
    k3s_unit="k3s-agent"
  fi

  if [ -n "$k3s_unit" ]; then
    echo "Parando $k3s_unit para copiar $LONGHORN_DIR de forma consistente..."
    systemctl stop "$k3s_unit"
    # shellcheck disable=SC2064 # expansao imediata e intencional: o trap tem de
    # saber QUAL unit religar, mesmo se a variavel mudar depois.
    trap "systemctl start $k3s_unit >/dev/null 2>&1 || true" EXIT
  else
    echo "Nenhum k3s ativo; nada a migrar (node novo)."
  fi

  cp -a "$LONGHORN_DIR/." "$TEMP_MOUNT/"
  sync
  umount "$TEMP_MOUNT"

  sed -i '\|[[:space:]]/var/lib/longhorn[[:space:]]|d' /etc/fstab
  printf 'UUID=%s %s ext4 defaults,_netdev,nofail 0 2\n' \
    "$volume_uuid" "$LONGHORN_DIR" >> /etc/fstab
  mount "$LONGHORN_DIR"

  if [ -n "$k3s_unit" ]; then
    systemctl start "$k3s_unit"
    trap - EXIT
  fi
}

install_ssh_key
configure_longhorn_volume

findmnt "$LONGHORN_DIR"
