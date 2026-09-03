#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"  # us_ashburn_1/

SSH_KEY_REF="op://Personal/Pessoal/private key?ssh-format=openssh"
SSH_PUBLIC_KEY_REF="op://Personal/Pessoal/public key"
SSH_KEY=""
# Porta usada durante o bootstrap. A VM nasce com o sshd na 22; so no fim do
# deploy, com o cluster de pe, o harden_ssh_port move para HARDENED_SSH_PORT e
# atualiza esta variavel. Assim nenhuma etapa do deploy depende de uma porta que
# ainda nao foi comprovada alcancavel.
SSH_PORT="${REGULUS_SSH_PORT:-22}"

# Porta definitiva do SSH. Precisa bater com ssh_port da unit network/vcn e com
# local.ssh_port da unit applications/compute/vm (que libera o iptables).
HARDENED_SSH_PORT="${REGULUS_HARDENED_SSH_PORT:-62222}"
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

# O .terragrunt-cache guarda a config de backend de quando foi gerado. Quando a
# copia local fica velha em relacao ao repositorio, o terraform recusa qualquer
# comando com "Backend configuration changed" e o -auto-approve nao tem como
# responder. Ja custou o destroy dos helm releases uma vez: o `|| true` engoliu
# a falha e o state seguiu com releases apontando para um cluster destruido.
# O state real vive no S3, entao reconfigurar o backend local e inofensivo.
tg_init() {
  terragrunt init -reconfigure --non-interactive >/dev/null
}

provision_vm() {
  echo "==> Provisionando VM (user_data instala K3s automaticamente)..."
  cd "$OCI_UNIT_DIR/network/vcn"
  tg_init
  terragrunt apply --auto-approve
  # IP reservado precisa existir antes da VM: seu endereco entra no user_data
  # (--tls-san) e e anexado a VNIC apos a criacao da instancia.
  cd "$OCI_UNIT_DIR/network/reserved_ip"
  tg_init
  terragrunt apply --auto-approve
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  tg_init
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

# Move o sshd da 22 para a porta alta, liberando a 22 para o honeypot.
#
# Roda no fim do deploy, e nao no cloud-init, por uma razao aprendida do jeito
# caro: dentro da VM nao da para saber se a porta nova ficou alcancavel de fora.
# Uma tentativa anterior conferia com `ss -lnt`, viu a porta escutando, seguiu
# adiante — e a VM ficou inacessivel nas duas portas, sem Run Command para
# resgatar. Aqui o teste e feito do lado de fora, contra o IP publico, e ha para
# onde voltar se ele falhar.
harden_ssh_port() {
  local vm_ip="$1"
  local ssh_base="ssh -i $SSH_KEY -p $SSH_PORT $SSH_OPTS $SSH_USER@$vm_ip"

  if [ "$SSH_PORT" = "$HARDENED_SSH_PORT" ]; then
    echo "==> SSH ja esta na porta $HARDENED_SSH_PORT; nada a fazer."
    return 0
  fi

  # Antes de tocar no sshd, provar que a porta alta e alcancavel de fora — com
  # um listener descartavel, nao por inferencia.
  #
  # A versao anterior tentava deduzir isso da mensagem de erro do TCP: tratava
  # "connection refused" como caminho livre e "No route to host" como iptables
  # barrando. Errado. Nesta VM uma porta liberada e SEM listener responde
  # "No route to host", e o teste abortava um caminho que estava perfeito.
  # Mensagem de erro de porta fechada nao distingue "sem processo" de
  # "bloqueado"; so um processo aceitando conexao distingue.
  echo "==> Provando que a porta $HARDENED_SSH_PORT e alcancavel de fora..."
  $ssh_base "nohup setsid timeout 60 python3 -c \"import socket;s=socket.socket();s.setsockopt(1,2,1);s.bind(('0.0.0.0',$HARDENED_SSH_PORT));s.listen(1);c,_=s.accept();c.send(b'PROBE-OK');c.close()\" >/dev/null 2>&1 < /dev/null &" \
    || { echo "ERROR: nao foi possivel subir o listener de teste na VM."; return 1; }
  sleep 5

  local probe=""
  local i
  for i in $(seq 1 6); do
    probe=$(timeout 10 bash -c "exec 3<>/dev/tcp/$vm_ip/$HARDENED_SSH_PORT; head -c 8 <&3" 2>/dev/null || true)
    [ "$probe" = "PROBE-OK" ] && break
    sleep 3
  done

  if [ "$probe" != "PROBE-OK" ]; then
    echo "ERROR: a porta $HARDENED_SSH_PORT nao respondeu nem com um listener ativo."
    echo "  Algo no caminho barra a porta: security list, iptables da VM ou rota."
    echo "  O sshd continua na 22 e o cluster segue acessivel; corrija o caminho"
    echo "  de rede antes de tentar de novo."
    return 1
  fi
  echo "  porta $HARDENED_SSH_PORT alcancavel; seguindo com a troca."

  # Dead man's switch: agenda a reversao DENTRO da VM antes de mexer no sshd.
  #
  # A versao anterior revertia de fora, por SSH na 22 — a mesma porta que a
  # troca derruba no instante em que e aplicada. Quando precisou reverter,
  # encontrou "No route to host" e a VM ficou inacessivel. Um canal de
  # recuperacao que depende do que a mudanca quebra nao e canal de recuperacao.
  #
  # Agora a VM se conserta sozinha: se este script nao cancelar o timer em 3
  # minutos, os drop-ins somem e o sshd volta para a 22, sem depender de rede,
  # de SSH ou de o operador estar por perto.
  echo "==> Armando rollback automatico na VM (3 min)..."
  $ssh_base "sudo systemd-run --unit=ssh-rollback --on-active=180 \
    /bin/sh -c 'rm -f /etc/ssh/sshd_config.d/99-regulus.conf /etc/systemd/system/ssh.socket.d/override.conf; systemctl daemon-reload; systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh'" \
    || { echo "ERROR: nao foi possivel armar o rollback; abortando com a 22 intacta."; return 1; }

  echo "==> Movendo o sshd para a porta $HARDENED_SSH_PORT..."
  # Drop-in em vez de editar sshd_config: o arquivo principal do Ubuntu abre com
  # Include /etc/ssh/sshd_config.d/*.conf e o cloud-image ja escreve ali.
  #
  # O override do ssh.socket e obrigatorio no Ubuntu 24.04: com socket
  # activation, a porta vem do ListenStream da unit e a diretiva Port do
  # sshd_config e ignorada sem aviso. O ListenStream= vazio zera a 22 herdada;
  # sem ele o systemd soma as duas portas.
  $ssh_base "sudo bash -s" <<REMOTE
set -euo pipefail
install -d -m 755 /etc/ssh/sshd_config.d
printf '%s\n' \
  "Port $HARDENED_SSH_PORT" \
  "PermitRootLogin no" \
  "PasswordAuthentication no" \
  "KbdInteractiveAuthentication no" \
  "PubkeyAuthentication yes" \
  > /etc/ssh/sshd_config.d/99-regulus.conf
sshd -t
if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
  install -d -m 755 /etc/systemd/system/ssh.socket.d
  # As duas familias precisam ser declaradas EXPLICITAMENTE.
  #
  # "ListenStream=<porta>" sozinho parece dual-stack, mas nesta imagem produz
  # apenas "[::]:<porta>" — so IPv6. Toda conexao IPv4 morre e o sintoma externo
  # e "No route to host", indistinguivel de firewall. Pior: "ss -lnt | grep
  # ':<porta> '" casa com a linha do IPv6 e reporta sucesso, entao qualquer
  # verificacao local passa enquanto ninguem consegue conectar. Foram duas VMs
  # perdidas ate isto aparecer em "systemctl show ssh.socket -p Listen".
  printf '%s\n' "[Socket]" "ListenStream=" \
    "ListenStream=0.0.0.0:$HARDENED_SSH_PORT" \
    "ListenStream=[::]:$HARDENED_SSH_PORT" \
    > /etc/systemd/system/ssh.socket.d/override.conf
  systemctl daemon-reload
  systemctl restart ssh.socket
else
  systemctl restart ssh
fi
REMOTE

  echo "==> Validando o SSH na porta $HARDENED_SSH_PORT (de fora)..."
  local ok=false
  local i
  for i in $(seq 1 12); do
    if ssh -i "$SSH_KEY" -p "$HARDENED_SSH_PORT" $SSH_OPTS "$SSH_USER@$vm_ip" true 2>/dev/null; then
      ok=true
      break
    fi
    echo "  tentativa $i/12 — ainda sem resposta em $HARDENED_SSH_PORT; aguardando 5s..."
    sleep 5
  done

  if [ "$ok" = false ]; then
    # Nada a fazer aqui alem de sair: o timer armado na VM devolve o sshd para a
    # 22 sozinho. Tentar reverter de fora seria justamente o erro anterior.
    echo "AVISO: $HARDENED_SSH_PORT nao respondeu."
    echo "  O rollback automatico na VM devolve o sshd para a 22 em ate 3 min."
    echo "  Aguarde e tente 'ssh -p 22'; nao e preciso recriar a VM."
    echo "ERROR: a mudanca de porta falhou. O honeypot NAO deve subir."
    return 1
  fi

  # Só agora o timer pode ser desarmado: a porta nova esta comprovadamente
  # respondendo de fora, com o SSH real e nao com um listener de teste.
  echo "==> Porta validada; desarmando o rollback automatico..."
  ssh -i "$SSH_KEY" -p "$HARDENED_SSH_PORT" $SSH_OPTS "$SSH_USER@$vm_ip" \
    "sudo systemctl stop ssh-rollback.timer 2>/dev/null; sudo systemctl reset-failed ssh-rollback.timer 2>/dev/null; true" \
    || echo "  AVISO: nao foi possivel desarmar o timer; o sshd pode voltar para a 22 em ate 3 min."

  SSH_PORT="$HARDENED_SSH_PORT"
  echo "SSH na porta $HARDENED_SSH_PORT confirmado; a 22 esta livre para o honeypot."
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
  tg_init

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
  # Antes esta funcao apenas imprimia estado e sempre "passava" — o deploy podia
  # terminar com exit 0 sobre um cluster quebrado. Agora ela afirma.
  local kc=(kubectl --kubeconfig "$KUBECONFIG_PATH")
  local falhas=0

  echo "==> Verificando cluster..."
  echo "--- Nodes ---"
  "${kc[@]}" get nodes
  echo "--- Storage classes ---"
  "${kc[@]}" get sc
  echo "--- ArgoCD apps ---"
  "${kc[@]}" get applications -n argocd 2>/dev/null || echo "(ArgoCD ainda nao sincronizou)"
  echo "--- Pods ---"
  "${kc[@]}" get pods -A

  echo "--- Verificacoes ---"

  if "${kc[@]}" get nodes --no-headers 2>/dev/null | grep -q ' Ready'; then
    echo "OK: node Ready."
  else
    echo "FALHA: nenhum node Ready."
    falhas=$((falhas + 1))
  fi

  # O IPAddressPool e o unico motivo de um Service LoadBalancer ganhar
  # EXTERNAL-IP neste cluster. Sem ele o Traefik nao publica IP no status do
  # Ingress e o external-dns para de atualizar o DNS — o cluster fica
  # inalcancavel por nome sem nada obvio quebrar.
  if "${kc[@]}" -n metallb-system get ipaddresspool default-pool >/dev/null 2>&1; then
    echo "OK: IPAddressPool do MetalLB presente."
  else
    echo "FALHA: IPAddressPool do MetalLB ausente."
    falhas=$((falhas + 1))
  fi

  # Prova de ponta a ponta de que o MetalLB esta entregando: so passa quando o
  # Service do Traefik realmente recebe o endereco.
  local ip=""
  for i in $(seq 1 60); do
    ip=$("${kc[@]}" -n traefik get svc traefik \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$ip" ]; then
      break
    fi
    echo "  aguardando EXTERNAL-IP no Service do Traefik ($i/60)..."
    sleep 10
  done
  if [ -n "$ip" ]; then
    echo "OK: Traefik com EXTERNAL-IP $ip."
  else
    echo "FALHA: Service do Traefik sem EXTERNAL-IP apos 10 min."
    "${kc[@]}" -n traefik get svc traefik 2>/dev/null || true
    falhas=$((falhas + 1))
  fi

  if [ "$falhas" -gt 0 ]; then
    echo "ERROR: verificacao encontrou $falhas problema(s); o cluster NAO esta funcional."
    exit 1
  fi
  echo "Cluster verificado."
}

destroy() {
  echo "==> Pre-destroy cleanup..."
  bash "$SCRIPT_DIR/pre-destroy.sh"

  echo "==> Destruindo helm releases..."
  cd "$SCRIPT_DIR/helms"
  tg_init
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
    # timeout: o k3s-uninstall.sh desmonta os mounts CSI do Longhorn com
    # `umount -f`. Se o longhorn-manager ja morreu, esse umount fica em estado D
    # — sono ininterrompivel, imune ate a SIGKILL — e o script nunca retorna.
    # Sem o timeout o `|| echo` abaixo jamais dispara e o destroy trava para
    # sempre a um passo de destruir a VM (visto na pratica: 28 min parado).
    # O uninstall e best-effort de qualquer forma: quem remove o cluster de fato
    # e o destroy da instancia, logo abaixo.
    timeout 300 ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS \
      "$SSH_USER@$vm_ip" "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null \
      || echo "K3s nao instalado, ja removido, ou uninstall expirou (a VM sera destruida a seguir)."
  else
    echo "==> Pulando uninstall do K3s (IP da VM indisponivel)."
  fi

  echo "==> Destruindo VM..."
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  tg_init
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
    # Obrigatoriamente antes do root app: o Cowrie sobe com hostPort 22 e
    # disputaria a porta com o sshd. Se o harden falhar, ele reverte para a 22 e
    # retorna erro — o set -e aborta aqui de proposito, deixando o cluster sem
    # os apps mas com acesso administrativo intacto. Subir o honeypot com o sshd
    # ainda na 22 seria a unica forma de perder as duas coisas ao mesmo tempo.
    harden_ssh_port "$VM_IP"
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
