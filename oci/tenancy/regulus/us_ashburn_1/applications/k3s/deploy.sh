#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"  # us_ashburn_1/

SSH_KEY_REF="op://Personal/Pessoal/private key?ssh-format=openssh"
SSH_PUBLIC_KEY_REF="op://Personal/Pessoal/public key"
SSH_KEY=""
SSH_PORT="22"
SSH_USER="ubuntu"
KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"
TEMP_SSH_KEY=""
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15"

cleanup() {
  if [ -n "$TEMP_SSH_KEY" ] && [ -f "$TEMP_SSH_KEY" ]; then
    rm -f "$TEMP_SSH_KEY"
  fi
}

trap cleanup EXIT

preflight_check() {
  if ! op vault list &>/dev/null; then
    echo "ERROR: 1Password CLI nao esta autenticado."
    echo "  Exporte OP_SERVICE_ACCOUNT_TOKEN ou rode: eval \$(op signin)"
    exit 1
  fi
}

prepare_ssh_key() {
  TEMP_SSH_KEY=$(mktemp /tmp/regulus-ssh-key.XXXXXX)
  op read --out-file "$TEMP_SSH_KEY" --file-mode 0600 --force "$SSH_KEY_REF" >/dev/null
  SSH_KEY="$TEMP_SSH_KEY"
}

get_vm_ip() {
  terragrunt output -raw instance_public_ip 2>/dev/null
}

provision_vm() {
  echo "==> Provisionando VM (user_data instala K3s automaticamente)..."
  cd "$OCI_UNIT_DIR/network/vcn"
  terragrunt apply --auto-approve
  # IP reservado precisa existir antes da VM: seu endereco entra no user_data
  # (--tls-san) e e anexado a VNIC apos a criacao da instancia.
  cd "$OCI_UNIT_DIR/network/reserved_ip"
  terragrunt apply --auto-approve
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  terragrunt apply --auto-approve
}

configure_regulus_host() {
  local vm_ip="$1"
  local script_b64 public_key_b64

  # O plugin "Compute Instance Run Command" nao e exposto nesta instancia
  # (a API responde "not present"), entao a configuracao vai por SSH — que ja
  # funciona porque o Terraform injeta ssh_authorized_keys na criacao da VM.
  script_b64=$(base64 -w0 "$SCRIPT_DIR/scripts/configure-regulus-host.sh")
  public_key_b64=$(op read "$SSH_PUBLIC_KEY_REF" | base64 -w0)

  echo "==> Configurando chave SSH e volume dedicado do Longhorn..."
  ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$vm_ip" \
    "printf '%s' '$script_b64' | base64 --decode | sudo REGULUS_SSH_PUBLIC_KEY_B64='$public_key_b64' bash"
  echo "Host Regulus configurado."
}

wait_for_k3s() {
  local vm_ip
  vm_ip=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && get_vm_ip)
  local SSH="ssh -i $SSH_KEY -p $SSH_PORT $SSH_OPTS $SSH_USER@$vm_ip"

  echo "==> VM IP: $vm_ip — aguardando K3s ficar Ready (cloud-init)..." >&2
  local retries=60
  for i in $(seq 1 $retries); do
    if $SSH "kubectl get nodes 2>/dev/null | grep -q ' Ready'" 2>/dev/null; then
      echo "K3s pronto." >&2
      echo "$vm_ip"
      return 0
    fi
    echo "  Tentativa $i/$retries — aguardando 15s..." >&2
    sleep 15
  done
  echo "ERROR: K3s nao ficou Ready." >&2
  exit 1
}

fetch_kubeconfig() {
  local vm_ip="$1"
  echo "==> Buscando kubeconfig da VM..."
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"

  local retries=20
  local success=false
  for i in $(seq 1 $retries); do
    if ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$vm_ip" "cat /etc/rancher/k3s/k3s.yaml" > /tmp/k3s-oci-raw.yaml 2>/dev/null; then
      success=true
      break
    fi
    echo "  Tentativa $i/$retries - aguardando SSH e K3s ficarem disponíveis..."
    sleep 15
  done

  if [ "$success" = false ]; then
    echo "ERROR: Não foi possível conectar via SSH após $retries tentativas"
    exit 1
  fi

  sed "s/127.0.0.1/$vm_ip/g" /tmp/k3s-oci-raw.yaml > "$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"
  echo "Kubeconfig salvo em $KUBECONFIG_PATH"
}

# Clean up stuck Terraform state locks and pending Helm releases
cleanup_helms_state() {
  echo "==> Limpando state locks e helm releases pendentes..."
  cd "$SCRIPT_DIR/helms"

  # Force-unlock any stuck state lock
  local lock_id
  lock_id=$(K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt plan 2>&1 | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1) || true
  if [ -n "${lock_id:-}" ]; then
    echo "  Removendo state lock $lock_id..."
    terragrunt force-unlock -force "$lock_id" 2>/dev/null || true
  fi

  # Clean up pending-install/pending-upgrade helm releases
  for ns in metallb-system cert-manager longhorn-system argocd; do
    kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$ns" get secret -l owner=helm -o jsonpath='{range .items[?(@.metadata.labels.status!="deployed")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | while read -r secret; do
      if [ -n "$secret" ]; then
        echo "  Removendo helm secret pendente: $ns/$secret"
        kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$ns" delete secret "$secret" 2>/dev/null || true
      fi
    done
  done
}

deploy_helms() {
  echo "==> Deploy helm releases (cert-manager, longhorn, argocd)..."
  cleanup_helms_state
  cd "$SCRIPT_DIR/helms"
  K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt apply --auto-approve
}

bootstrap_backup_secrets() {
  echo "==> Configurando credenciais minimas do Longhorn e RCON no 1Password/Kubernetes..."
  bash "$SCRIPT_DIR/bootstrap-longhorn-backup.sh"
}

restore_minecraft_data() {
  local kubectl_cmd=(kubectl --kubeconfig "$KUBECONFIG_PATH")
  local backup_target_manifest="$SCRIPT_DIR/argocd/manifests/longhorn-backup-config/backup-target.yaml"
  local pvc_manifest="$SCRIPT_DIR/argocd/manifests/minecraft/pvc.yaml"

  if "${kubectl_cmd[@]}" -n minecraft get pvc minecraft-data >/dev/null 2>&1; then
    echo "==> PVC do Minecraft ja existe; restauracao nao e necessaria."
    return 0
  fi

  echo "==> Sincronizando o catalogo remoto de backups do Longhorn..."
  "${kubectl_cmd[@]}" apply -f "$backup_target_manifest"

  local target_available="false"
  for i in $(seq 1 60); do
    target_available=$("${kubectl_cmd[@]}" -n longhorn-system get backuptarget default \
      -o jsonpath='{.status.available}' 2>/dev/null || true)
    if [ "$target_available" = "true" ]; then
      break
    fi
    echo "  BackupTarget ainda indisponivel ($i/60); aguardando 10s..."
    sleep 10
  done
  if [ "$target_available" != "true" ]; then
    echo "ERROR: BackupTarget do Longhorn nao ficou disponivel; PVC nao sera criado vazio."
    exit 1
  fi

  local backup_url=""
  for i in $(seq 1 60); do
    backup_url=$("${kubectl_cmd[@]}" -n longhorn-system get backups.longhorn.io -o json 2>/dev/null \
      | jq -r '[.items[]
          | select(.status.state == "Completed")
          | select(((.status.labels.KubernetesStatus // .spec.labels.KubernetesStatus // "{}") | fromjson? // {})
            | .namespace == "minecraft" and .pvcName == "minecraft-data")]
        | sort_by(.status.backupCreatedAt // .metadata.creationTimestamp)
        | last
        | .status.url // empty' || true)
    if [ -n "$backup_url" ]; then
      break
    fi
    echo "  Backup do Minecraft ainda nao apareceu no catalogo ($i/60); aguardando 10s..."
    sleep 10
  done
  if [ -z "$backup_url" ]; then
    echo "ERROR: nenhum backup completo do PVC minecraft/minecraft-data foi encontrado."
    echo "  Recusando criar um volume vazio durante uma recriacao do cluster."
    exit 1
  fi

  echo "==> Criando StorageClass de restauracao e PVC do Minecraft..."
  jq -n --arg from_backup "$backup_url" '{
    apiVersion: "storage.k8s.io/v1",
    kind: "StorageClass",
    metadata: {name: "minecraft-data"},
    provisioner: "driver.longhorn.io",
    allowVolumeExpansion: true,
    reclaimPolicy: "Delete",
    volumeBindingMode: "Immediate",
    parameters: {
      numberOfReplicas: "1",
      staleReplicaTimeout: "30",
      fromBackup: $from_backup,
      fsType: "ext4"
    }
  }' | "${kubectl_cmd[@]}" apply -f -
  "${kubectl_cmd[@]}" apply -f "$pvc_manifest"
  "${kubectl_cmd[@]}" -n minecraft wait --for=jsonpath='{.status.phase}'=Bound \
    pvc/minecraft-data --timeout=45m

  local volume_name restore_required
  volume_name=$("${kubectl_cmd[@]}" -n minecraft get pvc minecraft-data \
    -o jsonpath='{.spec.volumeName}')
  volume_name=$("${kubectl_cmd[@]}" get pv "$volume_name" \
    -o jsonpath='{.spec.csi.volumeHandle}')
  for i in $(seq 1 180); do
    restore_required=$("${kubectl_cmd[@]}" -n longhorn-system get volume "$volume_name" \
      -o jsonpath='{.status.restoreRequired}' 2>/dev/null || true)
    if [ "$restore_required" = "false" ]; then
      echo "Backup do Minecraft restaurado no volume $volume_name."
      return 0
    fi
    echo "  Restauracao Longhorn em andamento ($i/180); aguardando 10s..."
    sleep 10
  done

  echo "ERROR: restauracao do Minecraft nao terminou dentro de 30 minutos."
  exit 1
}

deploy_root_app() {
  # O root app precisa do repo-server de pe para gerar manifests. Aplicado antes
  # disso, o ArgoCD grava um ComparisonError ("connection refused" na 8081) e a
  # Application fica em Unknown ate alguem forcar um refresh na mao.
  echo "==> Aguardando ArgoCD ficar pronto..."
  kubectl --kubeconfig "$KUBECONFIG_PATH" -n argocd wait --for=condition=Available \
    deploy/argocd-repo-server deploy/argocd-server --timeout=300s || true

  echo "==> Aplicando ArgoCD root app-of-apps..."
  kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f "$SCRIPT_DIR/argocd/root-app.yaml"
}

verify() {
  echo "==> Verificando cluster..."
  echo "--- Nodes ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes
  echo "--- Storage classes ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get sc
  echo "--- ArgoCD apps ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get applications -n argocd 2>/dev/null || echo "(ArgoCD ainda nao sincronizou)"
  echo "--- Pods ---"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A
}

destroy() {
  echo "==> Pre-destroy cleanup..."
  bash "$SCRIPT_DIR/pre-destroy.sh"

  echo "==> Destruindo helm releases..."
  cd "$SCRIPT_DIR/helms"
  # Force-unlock before destroy too
  local lock_id
  lock_id=$(K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt plan 2>&1 | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1) || true
  if [ -n "${lock_id:-}" ]; then
    terragrunt force-unlock -force "$lock_id" 2>/dev/null || true
  fi
  # O `|| true` continua: a VM e destruida logo abaixo, entao um release orfao
  # no state e inofensivo — o apply seguinte reconcilia. O que faltava era
  # explicar POR QUE falhou. Sem isto, o timeout do longhorn-uninstall aparecia
  # apenas como "timed out waiting for the condition", sem causa.
  if ! K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt destroy --auto-approve; then
    echo "AVISO: destroy dos helm releases falhou. Coletando diagnostico..."
    local kc=(kubectl --kubeconfig "$KUBECONFIG_PATH" -n longhorn-system)
    "${kc[@]}" get jobs 2>/dev/null || true
    "${kc[@]}" logs job/longhorn-uninstall --tail=40 2>/dev/null \
      || echo "  (sem job longhorn-uninstall — a falha veio de outro release)"
    "${kc[@]}" get volumes.longhorn.io 2>/dev/null || true
  fi

  # Uninstall do K3s so agora: antes do destroy acima o cluster precisa estar
  # vivo, senao os helm releases ficam orfaos no state.
  local vm_ip
  vm_ip=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && get_vm_ip) || true
  if [ -n "${vm_ip:-}" ]; then
    echo "==> Desinstalando K3s na VM ($vm_ip)..."
    ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS \
      "$SSH_USER@$vm_ip" "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null \
      || echo "K3s nao instalado ou ja removido."
  else
    echo "==> Pulando uninstall do K3s (IP da VM indisponivel)."
  fi

  echo "==> Destruindo VM..."
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  terragrunt destroy --auto-approve || true
}

MODE="${1:-deploy}"

case "$MODE" in
  deploy)
    preflight_check
    provision_vm
    prepare_ssh_key
    VM_IP=$(wait_for_k3s)
    configure_regulus_host "$VM_IP"
    fetch_kubeconfig "$VM_IP"
    deploy_helms
    bootstrap_backup_secrets
    restore_minecraft_data
    deploy_root_app
    verify
    ;;
  helms-only)
    preflight_check
    deploy_helms
    bootstrap_backup_secrets
    restore_minecraft_data
    deploy_root_app
    ;;
  verify)
    verify
    ;;
  destroy)
    preflight_check
    prepare_ssh_key
    destroy
    ;;
  *)
    echo "Usage: $0 [deploy|helms-only|verify|destroy]"
    exit 1
    ;;
esac
