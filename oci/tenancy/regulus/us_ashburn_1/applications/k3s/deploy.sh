#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"  # us_ashburn_1/

SSH_KEY_REF="op://Personal/Pessoal/private key?ssh-format=openssh"
SSH_PUBLIC_KEY_REF="op://Personal/Pessoal/public key"
# Chave dedicada da VM de administracao (mercurio). Separada da chave do
# operador de proposito: o mercurio executa comandos arbitrarios em containers,
# entao a credencial dele tem de ser revogavel sozinha, sem tocar na sua.
MERCURIO_SSH_PUBLIC_KEY_REF="op://Lab-IAC/Mercurio SSH/public key"
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

# Descobre em qual porta o sshd desta VM atende.
#
# Uma VM recem-criada esta na 22; uma que ja passou pelo harden_ssh_port esta na
# porta alta. O destroy precisa falar com as duas, e fixar 22 fazia o uninstall
# do K3s falhar silenciosamente contra qualquer VM ja endurecida. Testa a porta
# alta primeiro porque e o estado normal de uma VM em producao.
# Ecoa a porta no stdout em vez de gravar em variavel global.
#
# Com uma VM so, uma global funcionava. Com duas, ela vira estado compartilhado
# errado: descobrir a porta da vm-regulus e depois usar esse valor para falar
# com a danebola acerta por acidente enquanto as duas estao iguais e erra em
# silencio no momento em que divergem — que e exatamente durante o harden.
detect_ssh_port() {
  local vm_ip="$1"
  local p
  for p in "$HARDENED_SSH_PORT" 22; do
    if ssh -i "$SSH_KEY" -p "$p" $SSH_OPTS -o ConnectTimeout=8 "$SSH_USER@$vm_ip" true 2>/dev/null; then
      echo "==> $vm_ip: sshd atende na porta $p." >&2
      echo "$p"
      return 0
    fi
  done
  echo "AVISO: $vm_ip: sshd nao respondeu em $HARDENED_SSH_PORT nem na 22; assumindo $SSH_PORT." >&2
  echo "$SSH_PORT"
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
  echo "==> Provisionando VMs do cluster..."
  cd "$OCI_UNIT_DIR/network/vcn"
  tg_init
  terragrunt apply --auto-approve
  # IP reservado precisa existir antes da VM: seu endereco entra no user_data
  # (--tls-san) e e anexado a VNIC apos a criacao da instancia.
  cd "$OCI_UNIT_DIR/network/reserved_ip"
  tg_init
  terragrunt apply --auto-approve

  # vm-regulus: o user_data instala o k3s server sozinho.
  echo "==> Provisionando vm-regulus (control plane)..."
  cd "$OCI_UNIT_DIR/applications/compute/vm"
  tg_init
  terragrunt apply --auto-approve

  # danebola: o user_data NAO instala k3s. Ela sobe preparada (open-iscsi,
  # iptables) e o join acontece em join_agent, por SSH, porque o token do
  # server nao pode passar por user_data — ver o comentario na unit.
  echo "==> Provisionando danebola (node escravo)..."
  cd "$OCI_UNIT_DIR/applications/compute/danebola"
  tg_init
  terragrunt apply --auto-approve
}

# IP publico da danebola. Separado de get_vm_ip porque as duas units tem
# diretorios distintos e o output e lido no diretorio da unit.
#
# Valida o formato em vez de apenas testar se veio vazio: quando a unit nao tem
# state, o terragrunt decora o erro no STDOUT, entao a substituicao de comando
# captura moldura ANSI em vez de string vazia. Visto no destroy de 04/09/2026,
# que anunciou "Desinstalando o k3s agent na danebola (╷" e gastou um ciclo de
# SSH contra um host inexistente. Mesmo defeito do stdout poluido do
# wait_for_k3s, com outra origem.
get_danebola_ip() {
  local ip
  ip=$( (cd "$OCI_UNIT_DIR/applications/compute/danebola" && terragrunt output -raw instance_public_ip 2>/dev/null) )
  if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "$ip"
  fi
}

# Instala o k3s agent na danebola e a junta ao cluster.
#
# O token vive em /var/lib/rancher/k3s/server/node-token no server e so existe
# depois de ele subir. Ele viaja server -> aqui -> danebola sempre por SSH:
# nunca entra em user_data (legivel em metadata de instancia) nem em state do
# Terraform.
#
# --node-label workload=minecraft e o que prende o Minecraft aqui. Sem o label,
# a colocacao dependeria apenas de o request de 7Gi nao caber na vm-regulus
# (2/8) — aritmetica de scheduler que quebra em silencio no dia que alguem
# mexer no request ou no tamanho da VM.
join_agent() {
  local server_ip="$1" agent_ip="$2" token version

  # A versao vem do server que esta rodando, nao de uma constante aqui. Ter o
  # numero em dois lugares (locals da unit e este script) e a mesma armadilha do
  # par seed/ArgoCD: divergem em silencio e o agent entra com versao diferente
  # do control plane.
  version=$(ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$server_ip" \
    "k3s --version | head -1 | awk '{print \$3}'")
  if [ -z "${version:-}" ]; then
    echo "ERROR: nao consegui ler a versao do k3s no server."
    exit 1
  fi
  echo "==> Server roda k3s $version; o agent vai usar a mesma."

  echo "==> Lendo o token do server..."
  token=$(ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$server_ip" \
    "sudo cat /var/lib/rancher/k3s/server/node-token")
  if [ -z "${token:-}" ]; then
    echo "ERROR: token do k3s vazio; o server subiu?"
    exit 1
  fi

  echo "==> Instalando k3s agent na danebola ($agent_ip)..."
  ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$agent_ip" \
    "curl -sfL https://get.k3s.io \
       | sudo INSTALL_K3S_VERSION='$version' \
              K3S_URL='https://$server_ip:6443' \
              K3S_TOKEN='$token' \
              sh -s - agent --node-label workload=minecraft"

  echo "==> Aguardando a danebola aparecer Ready no cluster..."
  local i
  for i in $(seq 1 40); do
    if ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$server_ip" \
         "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready'" 2>/dev/null \
         | grep -q '^2$'; then
      echo "  cluster com 2 nodes Ready."
      return 0
    fi
    echo "  tentativa $i/40 — ainda nao ha 2 nodes Ready; aguardando 15s..."
    sleep 15
  done
  echo "ERROR: a danebola nao entrou no cluster."
  exit 1
}

configure_regulus_host() {
  local vm_ip="$1"
  local script_b64 public_key_b64 mercurio_key_b64

  # O plugin "Compute Instance Run Command" nao e exposto nesta instancia
  # (a API responde "not present"), entao a configuracao vai por SSH — que ja
  # funciona porque o Terraform injeta ssh_authorized_keys na criacao da VM.
  script_b64=$(base64 -w0 "$SCRIPT_DIR/scripts/configure-regulus-host.sh")
  public_key_b64=$(op read "$SSH_PUBLIC_KEY_REF" | base64 -w0)

  # Falha alto se a chave do mercurio nao estiver no cofre, em vez de seguir
  # calado: um cluster sem ela e um cluster que o mercurio nao administra, e
  # descobrir isso depois custa mais do que abortar aqui.
  mercurio_key_b64=$(op read "$MERCURIO_SSH_PUBLIC_KEY_REF" | base64 -w0)
  if [ -z "${mercurio_key_b64:-}" ]; then
    echo "ERROR: nao consegui ler $MERCURIO_SSH_PUBLIC_KEY_REF do cofre."
    exit 1
  fi

  echo "==> Configurando chaves SSH e volume do Longhorn em ${2:-$vm_ip}..."
  ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$vm_ip" \
    "printf '%s' '$script_b64' | base64 --decode | sudo REGULUS_SSH_PUBLIC_KEY_B64='$public_key_b64' MERCURIO_SSH_PUBLIC_KEY_B64='$mercurio_key_b64' bash"
  echo "Host ${2:-$vm_ip} configurado."
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
  local port_now

  # Sonda ESTA VM em vez de consultar a global. A versao anterior lia $SSH_PORT
  # e, no fim, gravava $HARDENED_SSH_PORT nela — o que funcionava com uma VM e
  # quebrava calado com duas: apos endurecer a primeira, a global ja valia
  # 62222, a segunda chamada caia neste atalho e a VM ficava com sshd real na
  # 22 enquanto o script anunciava "nada a fazer".
  port_now=$(detect_ssh_port "$vm_ip")
  if [ "$port_now" = "$HARDENED_SSH_PORT" ]; then
    echo "==> $vm_ip ja atende na porta $HARDENED_SSH_PORT; nada a fazer."
    return 0
  fi

  local ssh_base="ssh -i $SSH_KEY -p $port_now $SSH_OPTS $SSH_USER@$vm_ip"

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

  # Restaura o backup que o pre-destroy registrou, NAO "o mais recente".
  #
  # O catalogo do Longhorn e populado por uma sincronizacao assincrona a partir
  # do S3, e num cluster recem-criado ele comeca vazio e vai enchendo. A versao
  # anterior esperava aparecer QUALQUER backup do minecraft e pegava o mais novo
  # da lista — que, no meio da sincronizacao, e o mais novo dos que ja chegaram,
  # nao o mais novo que existe.
  #
  # Custou o mundo em 04/09/2026: backup final pronto as 18:19 UTC, catalogo o
  # indexou as 19:15, restore rodou entre os dois e escolheu um backup de 02/09.
  # O deploy imprimiu "Backup do Minecraft restaurado" e estava tecnicamente
  # certo — restaurou, so que o errado.
  #
  # Esperar mais tempo nao resolveria: nao existe sinal de "a sincronizacao
  # terminou", so de "ainda nao terminou". Esperar por um NOME especifico, sim:
  # ou ele aparece, ou o deploy falha alto em vez de restaurar outra coisa.
  local backup_record="$SCRIPT_DIR/.ultimo-backup-minecraft"
  local wanted_backup=""
  [ -f "$backup_record" ] && wanted_backup=$(tr -d '[:space:]' < "$backup_record")

  if [ -z "$wanted_backup" ]; then
    echo "ERROR: $backup_record nao existe ou esta vazio."
    echo "  Esse arquivo e escrito pelo pre-destroy.sh com o nome do backup final."
    echo "  Sem ele, restaurar significaria adivinhar — e foi adivinhando que o"
    echo "  mundo voltou dois dias e meio em 04/09/2026. Deploy cancelado."
    echo "  Para restaurar um backup especifico a mao, escreva o nome dele ali."
    exit 1
  fi

  echo "==> Aguardando o backup $wanted_backup aparecer no catalogo..."
  local backup_url=""
  for i in $(seq 1 60); do
    backup_url=$("${kubectl_cmd[@]}" -n longhorn-system get backups.longhorn.io \
      "$wanted_backup" -o jsonpath='{.status.url}' 2>/dev/null || true)
    local state
    state=$("${kubectl_cmd[@]}" -n longhorn-system get backups.longhorn.io \
      "$wanted_backup" -o jsonpath='{.status.state}' 2>/dev/null || true)
    if [ -n "$backup_url" ] && [ "$state" = "Completed" ]; then
      break
    fi
    backup_url=""
    echo "  ainda nao sincronizado (estado='${state:-ausente}') ($i/60); aguardando 10s..."
    sleep 10
  done
  if [ -z "$backup_url" ]; then
    echo "ERROR: o backup $wanted_backup nao apareceu Completed no catalogo em 10 min."
    echo "  Recusando restaurar outro backup no lugar dele, e recusando criar"
    echo "  volume vazio. Verifique o backupstore no S3 antes de prosseguir."
    exit 1
  fi
  echo "  encontrado: $backup_url"

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
  #
  # A danebola primeiro, e de proposito: ela roda o agent, que depende do
  # server. Desinstalar o server antes deixaria o agent falando com um endereco
  # morto e o k3s-agent-uninstall.sh esperando timeout sem necessidade.
  local danebola_ip danebola_port
  danebola_ip=$(get_danebola_ip) || true
  if [ -n "${danebola_ip:-}" ]; then
    danebola_port=$(detect_ssh_port "$danebola_ip")
    echo "==> Desinstalando o k3s agent na danebola ($danebola_ip)..."
    timeout 300 ssh -i "$SSH_KEY" -p "$danebola_port" $SSH_OPTS \
      "$SSH_USER@$danebola_ip" "sudo /usr/local/bin/k3s-agent-uninstall.sh" 2>/dev/null \
      || echo "  agent nao instalado, ja removido, ou uninstall expirou (a VM sera destruida a seguir)."
  else
    echo "==> Pulando uninstall do agent (IP da danebola indisponivel)."
  fi

  local vm_ip vm_port
  vm_ip=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && get_vm_ip) || true
  if [ -n "${vm_ip:-}" ]; then
    vm_port=$(detect_ssh_port "$vm_ip")
    SSH_PORT="$vm_port"
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

  # A danebola primeiro: ela nao tem dependencia que a prenda, e destrui-la
  # antes libera a franquia de A1 caso o destroy da vm-regulus precise de nova
  # tentativa.
  echo "==> Destruindo danebola..."
  cd "$OCI_UNIT_DIR/applications/compute/danebola"
  tg_init
  terragrunt destroy --auto-approve || true

  echo "==> Destruindo vm-regulus..."
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
    DANEBOLA_IP=$(get_danebola_ip)
    if [ -z "${DANEBOLA_IP:-}" ]; then
      echo "ERROR: IP da danebola indisponivel; o apply da unit falhou?"
      exit 1
    fi

    # O volume do Longhorn tem de estar montado nas DUAS VMs antes de o
    # deploy_helms instalar o Longhorn: e o mount que da ao node os 100 GB.
    # Sem isso o Longhorn adota /var/lib/longhorn no boot volume e passa a
    # agendar replica em disco que nao aguenta os PVCs.
    configure_regulus_host "$VM_IP" "vm-regulus"
    configure_regulus_host "$DANEBOLA_IP" "danebola"

    # Antes do deploy_helms tambem: o Longhorn precisa ver os 2 nodes para
    # colocar as 2 replicas de cada volume. Se ele subir com 1 node, os volumes
    # nascem degradados e so reconciliam depois.
    join_agent "$VM_IP" "$DANEBOLA_IP"

    fetch_kubeconfig "$VM_IP"
    deploy_helms
    bootstrap_backup_secrets
    restore_minecraft_data
    # Obrigatoriamente antes do root app: o Cowrie sobe com hostPort 22 e
    # disputaria a porta com o sshd. Se o harden falhar, ele reverte para a 22 e
    # retorna erro — o set -e aborta aqui de proposito, deixando o cluster sem
    # os apps mas com acesso administrativo intacto. Subir o honeypot com o sshd
    # ainda na 22 seria a unica forma de perder as duas coisas ao mesmo tempo.
    #
    # Nas duas VMs: a danebola nao tem honeypot para ocupar a 22, mas deixar um
    # sshd real exposto la seria o elo mais fraco de um cluster cujo outro node
    # esta na porta alta.
    harden_ssh_port "$VM_IP"
    harden_ssh_port "$DANEBOLA_IP"
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
