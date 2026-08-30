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
TEMP_SSH_PUBLIC_KEY=""
RECOVERY_INSTANCE_ID=""
RECOVERY_VOLUME_ATTACHMENT_ID=""
RECOVERY_BOOT_VOLUME_ID=""
REGULUS_INSTANCE_ID=""
REGULUS_WAS_STOPPED=false

cleanup() {
  # A recuperacao da chave usa uma VM efemera. Se qualquer etapa falhar depois
  # de tirar o boot volume da Regulus, devolva-o antes de remover a VM auxiliar.
  if [ -n "$RECOVERY_VOLUME_ATTACHMENT_ID" ]; then
    oci compute volume-attachment detach \
      --volume-attachment-id "$RECOVERY_VOLUME_ATTACHMENT_ID" --force \
      --wait-for-state DETACHED >/dev/null 2>&1 || true
    RECOVERY_VOLUME_ATTACHMENT_ID=""
  fi
  if [ -n "$RECOVERY_BOOT_VOLUME_ID" ] && [ -n "$REGULUS_INSTANCE_ID" ]; then
    local attached_instance
    attached_instance=$(oci compute boot-volume-attachment list \
      --availability-domain "$(oci compute instance get --instance-id "$REGULUS_INSTANCE_ID" --query 'data."availability-domain"' --raw-output 2>/dev/null)" \
      --compartment-id "$(oci compute instance get --instance-id "$REGULUS_INSTANCE_ID" --query 'data."compartment-id"' --raw-output 2>/dev/null)" \
      --boot-volume-id "$RECOVERY_BOOT_VOLUME_ID" \
      --query 'data[0]."instance-id"' --raw-output 2>/dev/null || true)
    if [ -z "$attached_instance" ] || [ "$attached_instance" = "None" ]; then
      oci compute boot-volume-attachment attach \
        --instance-id "$REGULUS_INSTANCE_ID" \
        --boot-volume-id "$RECOVERY_BOOT_VOLUME_ID" \
        --wait-for-state ATTACHED >/dev/null 2>&1 || true
    fi
    if [ "$REGULUS_WAS_STOPPED" = true ]; then
      oci compute instance action --instance-id "$REGULUS_INSTANCE_ID" \
        --action START --wait-for-state RUNNING >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$RECOVERY_INSTANCE_ID" ]; then
    oci compute instance terminate --instance-id "$RECOVERY_INSTANCE_ID" \
      --preserve-boot-volume false --force --wait-for-state TERMINATED >/dev/null 2>&1 || true
  fi
  if [ -n "$TEMP_SSH_KEY" ] && [ -f "$TEMP_SSH_KEY" ]; then
    rm -f "$TEMP_SSH_KEY"
  fi
  if [ -n "$TEMP_SSH_PUBLIC_KEY" ] && [ -f "$TEMP_SSH_PUBLIC_KEY" ]; then
    rm -f "$TEMP_SSH_PUBLIC_KEY"
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
  TEMP_SSH_PUBLIC_KEY=$(mktemp /tmp/regulus-ssh-public-key.XXXXXX)
  op read --out-file "$TEMP_SSH_PUBLIC_KEY" --file-mode 0600 --force "$SSH_PUBLIC_KEY_REF" >/dev/null
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

recover_regulus_ssh_key() {
  REGULUS_INSTANCE_ID=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && terragrunt output -raw instance_id)
  local instance_json availability_domain compartment_id subnet_id image_id recovery_ip
  instance_json=$(oci compute instance get --instance-id "$REGULUS_INSTANCE_ID")
  availability_domain=$(jq -r '.data["availability-domain"]' <<<"$instance_json")
  compartment_id=$(jq -r '.data["compartment-id"]' <<<"$instance_json")
  subnet_id=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && terragrunt output -raw primary_subnet_id)
  image_id=$(oci compute image list \
    --compartment-id "$compartment_id" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "24.04" \
    --shape "VM.Standard.E2.1.Micro" \
    --sort-by TIMECREATED --sort-order DESC --all \
    --query 'data[0].id' --raw-output)

  echo "==> Criando VM efemera para recuperar a chave SSH da Regulus..."
  RECOVERY_INSTANCE_ID=$(oci compute instance launch \
    --availability-domain "$availability_domain" \
    --compartment-id "$compartment_id" \
    --subnet-id "$subnet_id" \
    --shape "VM.Standard.E2.1.Micro" \
    --image-id "$image_id" \
    --display-name "regulus-ssh-recovery" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$TEMP_SSH_PUBLIC_KEY" \
    --wait-for-state RUNNING \
    --query 'data.id' --raw-output)
  recovery_ip=$(oci compute instance list-vnics --instance-id "$RECOVERY_INSTANCE_ID" \
    --query 'data[0]."public-ip"' --raw-output)

  echo "==> Aguardando SSH da VM de recuperacao..."
  for i in $(seq 1 40); do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "ubuntu@$recovery_ip" true 2>/dev/null; then
      break
    fi
    if [ "$i" -eq 40 ]; then
      echo "ERROR: VM de recuperacao nao aceitou SSH."
      exit 1
    fi
    sleep 10
  done

  local boot_attachment_json boot_attachment_id
  boot_attachment_json=$(oci compute boot-volume-attachment list \
    --availability-domain "$availability_domain" \
    --compartment-id "$compartment_id" \
    --instance-id "$REGULUS_INSTANCE_ID" \
    --query 'data[0]')
  boot_attachment_id=$(jq -r '."boot-volume-attachment-id" // .id' <<<"$boot_attachment_json")
  RECOVERY_BOOT_VOLUME_ID=$(jq -r '."boot-volume-id"' <<<"$boot_attachment_json")

  echo "==> Parando a Regulus e anexando seu boot volume na VM de recuperacao..."
  oci compute instance action --instance-id "$REGULUS_INSTANCE_ID" \
    --action SOFTSTOP --wait-for-state STOPPED >/dev/null
  REGULUS_WAS_STOPPED=true
  oci compute boot-volume-attachment detach \
    --boot-volume-attachment-id "$boot_attachment_id" --force \
    --wait-for-state DETACHED >/dev/null
  RECOVERY_VOLUME_ATTACHMENT_ID=$(oci compute volume-attachment attach \
    --instance-id "$RECOVERY_INSTANCE_ID" \
    --volume-id "$RECOVERY_BOOT_VOLUME_ID" \
    --type paravirtualized \
    --device "/dev/oracleoci/oraclevdb" \
    --display-name "regulus-boot-recovery" \
    --wait-for-state ATTACHED \
    --query 'data.id' --raw-output)

  local recovery_script_b64 public_key_b64
  recovery_script_b64=$(base64 -w0 "$SCRIPT_DIR/scripts/recover-regulus-ssh.sh")
  public_key_b64=$(base64 -w0 "$TEMP_SSH_PUBLIC_KEY")
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "ubuntu@$recovery_ip" \
    "printf '%s' '$recovery_script_b64' | base64 --decode | sudo REGULUS_SSH_PUBLIC_KEY_B64='$public_key_b64' bash"

  echo "==> Devolvendo o boot volume e iniciando a Regulus..."
  oci compute volume-attachment detach \
    --volume-attachment-id "$RECOVERY_VOLUME_ATTACHMENT_ID" --force \
    --wait-for-state DETACHED >/dev/null
  RECOVERY_VOLUME_ATTACHMENT_ID=""
  oci compute boot-volume-attachment attach \
    --instance-id "$REGULUS_INSTANCE_ID" \
    --boot-volume-id "$RECOVERY_BOOT_VOLUME_ID" \
    --wait-for-state ATTACHED >/dev/null
  RECOVERY_BOOT_VOLUME_ID=""
  oci compute instance action --instance-id "$REGULUS_INSTANCE_ID" \
    --action START --wait-for-state RUNNING >/dev/null
  REGULUS_WAS_STOPPED=false
  oci compute instance terminate --instance-id "$RECOVERY_INSTANCE_ID" \
    --preserve-boot-volume false --force --wait-for-state TERMINATED >/dev/null
  RECOVERY_INSTANCE_ID=""
}

configure_regulus_host() {
  local vm_ip public_key_b64 script_b64
  vm_ip=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && get_vm_ip)

  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "$SSH_USER@$vm_ip" true 2>/dev/null; then
    recover_regulus_ssh_key
  fi

  echo "==> Configurando chave SSH e volume dedicado do Longhorn..."
  script_b64=$(base64 -w0 "$SCRIPT_DIR/scripts/configure-regulus-host.sh")
  public_key_b64=$(base64 -w0 "$TEMP_SSH_PUBLIC_KEY")
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$vm_ip" \
    "printf '%s' '$script_b64' | base64 --decode | sudo REGULUS_SSH_PUBLIC_KEY_B64='$public_key_b64' bash"
}

wait_for_k3s() {
  local vm_ip
  vm_ip=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && get_vm_ip)
  local SSH="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no $SSH_USER@$vm_ip"

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
    if ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$vm_ip" "cat /etc/rancher/k3s/k3s.yaml" > /tmp/k3s-oci-raw.yaml 2>/dev/null; then
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
  K3S_OCI_KUBECONFIG="$KUBECONFIG_PATH" terragrunt destroy --auto-approve || true

  # Uninstall do K3s so agora: antes do destroy acima o cluster precisa estar
  # vivo, senao os helm releases ficam orfaos no state.
  local vm_ip
  vm_ip=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && get_vm_ip) || true
  if [ -n "${vm_ip:-}" ]; then
    echo "==> Desinstalando K3s na VM ($vm_ip)..."
    ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
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
    configure_regulus_host
    VM_IP=$(wait_for_k3s)
    fetch_kubeconfig "$VM_IP"
    deploy_helms
    bootstrap_backup_secrets
    deploy_root_app
    verify
    ;;
  helms-only)
    preflight_check
    deploy_helms
    bootstrap_backup_secrets
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
