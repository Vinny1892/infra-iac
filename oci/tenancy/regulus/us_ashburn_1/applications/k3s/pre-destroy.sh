#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_UNIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="22"
SSH_USER="ubuntu"
KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"
KUBECTL="kubectl --kubeconfig $KUBECONFIG_PATH"

# Get VM IP dynamically from Terraform state
VM_IP=$(cd "$OCI_UNIT_DIR/applications/compute/vm" && terragrunt output -raw instance_public_ip 2>/dev/null) || true

backup_minecraft_world() {
  # O destroy abaixo remove todos os PVCs. Para o mundo do Minecraft isso so e
  # seguro depois que o Job fizer save-all via RCON e o Longhorn confirmar que
  # a copia remota no S3 terminou. Falha fechada: nao perder mundo silenciosamente.
  if ! $KUBECTL get cronjob minecraft-longhorn-backup -n minecraft >/dev/null 2>&1; then
    echo "==> Minecraft backup CronJob nao encontrado; pulando (app ainda nao instalado)."
    return 0
  fi

  local job_name="minecraft-final-backup-$(date +%s)"
  echo "==> Executando backup remoto final do Minecraft ($job_name)..."
  $KUBECTL create job --from=cronjob/minecraft-longhorn-backup "$job_name" -n minecraft

  # Espera pelas DUAS condicoes terminais, nao so pela de sucesso.
  #
  # `wait --for=condition=complete` sozinho nao retorna quando o Job vai a
  # Failed: ele fica ate o timeout. Com 45m isso significa 45 minutos parado
  # esperando algo que ja acabou mal — visto na pratica em 04/09/2026, quando o
  # pod do Minecraft ficou Pending (nodeSelector sem node correspondente), o
  # backup falhou em 2 minutos e o destroy seguiu preso.
  #
  # Dois `wait` em paralelo, e o primeiro a terminar decide. Sem `wait -n` do
  # bash porque o que interessa e QUAL condicao bateu, nao qual PID saiu.
  local complete_pid failed_pid outcome=""
  $KUBECTL wait -n minecraft --for=condition=complete "job/$job_name" --timeout=45m >/dev/null 2>&1 &
  complete_pid=$!
  $KUBECTL wait -n minecraft --for=condition=failed "job/$job_name" --timeout=45m >/dev/null 2>&1 &
  failed_pid=$!

  while :; do
    if ! kill -0 "$complete_pid" 2>/dev/null; then
      wait "$complete_pid" && outcome="complete"
      break
    fi
    if ! kill -0 "$failed_pid" 2>/dev/null; then
      wait "$failed_pid" && outcome="failed"
      break
    fi
    sleep 5
  done
  kill "$complete_pid" "$failed_pid" 2>/dev/null || true

  if [ "$outcome" != "complete" ]; then
    echo "ERROR: backup remoto final do Minecraft nao concluiu (${outcome:-timeout});"
    echo "  destroy cancelado para preservar o PVC."
    $KUBECTL get pods -n minecraft -l "job-name=$job_name" 2>/dev/null || true
    $KUBECTL logs -n minecraft "job/$job_name" --all-containers=true 2>/dev/null || true
    exit 1
  fi

  echo "==> Backup remoto final do Minecraft concluido."
}

delete_argocd_applications() {
  if ! $KUBECTL get crd applications.argoproj.io >/dev/null 2>&1; then
    echo "==> ArgoCD nao instalado; nenhuma Application a remover."
    return 0
  fi

  local apps
  apps=$($KUBECTL get applications -n argocd -o name 2>/dev/null || true)
  if [ -z "$apps" ]; then
    echo "==> Nenhuma Application do ArgoCD encontrada."
    return 0
  fi

  # O finalizer resources-finalizer.argocd.argoproj.io segura o delete ate o
  # ArgoCD cascatear a remocao dos recursos gerenciados. Mas o proprio ArgoCD e
  # uma das Applications: apagar todas de uma vez derruba o controller que
  # deveria processar os finalizers das demais. O delete expirava, o erro era
  # engolido, e as Applications sobreviviam — com os workloads de pe segurando
  # os PVCs. Aqui a cascata nao e necessaria, porque os workloads sao removidos
  # explicitamente no passo seguinte; sem o finalizer o delete e imediato.
  echo "==> Removendo finalizers das Applications do ArgoCD..."
  local app
  for app in $apps; do
    $KUBECTL patch "$app" -n argocd --type merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done

  echo "==> Removendo Applications do ArgoCD..."
  if ! $KUBECTL delete applications -n argocd --all --timeout=120s; then
    echo "  AVISO: o delete das Applications nao concluiu no prazo; destravando."
    # A Application `argocd` e self-managed: ao apaga-la, o controller que
    # processaria o proprio finalizer morre junto e ela fica presa em
    # Terminating com o finalizer de volta. Observado num ciclo real — 14 das 15
    # Applications sairam limpas e apenas esta ficou. Uma segunda passada nas
    # que sobraram destrava; a primeira passada nao basta porque o finalizer
    # reaparece durante a propria remocao.
    local preso
    for preso in $($KUBECTL get applications -n argocd -o name 2>/dev/null || true); do
      echo "  destravando $preso"
      $KUBECTL patch "$preso" -n argocd --type merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done

    for i in $(seq 1 12); do
      if [ "$($KUBECTL get applications -n argocd --no-headers 2>/dev/null | wc -l || true)" -eq 0 ]; then
        echo "  Todas as Applications removidas."
        return 0
      fi
      sleep 5
    done
    echo "  AVISO: ainda restam Applications:"
    $KUBECTL get applications -n argocd 2>/dev/null || true
  fi
}

delete_operator_workload_crs() {
  # Remover o finalizer das Applications (ver delete_argocd_applications) destrava
  # o delete, mas tem um custo: o ArgoCD deixa de cascatear a remocao dos recursos
  # que geria. Para Deployment comum isso nao importa — delete_pvc_workloads os
  # apaga direto. Para carga gerida por operator, importa muito: a CR sobrevive,
  # o operator reconcilia e RECRIA o Deployment que acabou de ser apagado, e o pod
  # novo volta a segurar o PVC.
  #
  # Observado com o VictoriaLogs: o vlsingle renascia, o delete de PVCs expirava e
  # os volumes do Longhorn nunca drenavam. A CR precisa morrer antes do workload.
  local kinds="vlsingle vlagent vlcluster vmsingle vmagent vmcluster vmalert vmalertmanager"
  local kind encontrou=0
  for kind in $kinds; do
    $KUBECTL get crd "${kind}s.operator.victoriametrics.com" >/dev/null 2>&1 || continue
    if [ -n "$($KUBECTL get "$kind" -A --no-headers 2>/dev/null || true)" ]; then
      echo "  removendo CRs do tipo $kind"
      $KUBECTL delete "$kind" --all -A --timeout=60s >/dev/null 2>&1 || true
      encontrou=1
    fi
  done
  [ "$encontrou" -eq 0 ] && echo "  nenhuma CR de operator encontrada."
  return 0
}

delete_pvc_workloads() {
  # Um PVC nao e removido enquanto algum pod o monta: o finalizer
  # kubernetes.io/pvc-protection o mantem em Terminating indefinidamente. Sem
  # derrubar os workloads antes, o delete de PVCs expira, o Longhorn nunca
  # recebe ordem de apagar os volumes, e o job longhorn-uninstall trava
  # esperando volumes que ninguem mandou remover.
  local namespaces
  # `|| true`: com set -o pipefail, um kubectl que falha (cluster ja inexistente)
  # derruba a atribuicao inteira e, por set -e, o script.
  namespaces=$($KUBECTL get pvc -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u || true)
  if [ -z "$namespaces" ]; then
    echo "==> Nenhum PVC no cluster; nada a derrubar."
    return 0
  fi

  echo "==> Derrubando workloads que montam PVC..."
  local ns
  for ns in $namespaces; do
    # longhorn-system e kube-system ficam de pe: e o Longhorn quem processa a
    # remocao dos volumes, e derrubar o CSI aqui deixaria os PVCs orfaos.
    case "$ns" in
      longhorn-system | kube-system) continue ;;
    esac
    echo "  namespace $ns"
    $KUBECTL -n "$ns" delete deployment,statefulset,daemonset --all --timeout=120s 2>/dev/null || true
  done

  # Conta apenas o que de fato segura PVC. Uma versao anterior contava todos os
  # pods do namespace e nunca chegava a zero, emitindo aviso mesmo com o destroy
  # correndo bem: sobram pods `Completed` de Job (o backup final do Minecraft,
  # por exemplo) e cargas geridas por CR de operator (vmagent), que nao sao
  # Deployment/StatefulSet/DaemonSet e nao montam volume nenhum.
  echo "==> Aguardando os pods liberarem os PVCs..."
  local i restantes
  for i in $(seq 1 30); do
    restantes=0
    for ns in $namespaces; do
      case "$ns" in
        longhorn-system | kube-system) continue ;;
      esac
      restantes=$((restantes + $($KUBECTL -n "$ns" get pods -o json 2>/dev/null \
        | jq '[.items[]
             | select(.status.phase == "Running" or .status.phase == "Pending")
             | select(any(.spec.volumes[]?; has("persistentVolumeClaim")))]
           | length' 2>/dev/null || echo 0)))
    done
    if [ "$restantes" -eq 0 ]; then
      echo "  Nenhum pod segurando PVC."
      return 0
    fi
    echo "  $restantes pod(s) ainda segurando PVC ($i/30); aguardando 5s..."
    sleep 5
  done

  echo "  AVISO: ainda ha $restantes pod(s) segurando PVC; o delete abaixo pode expirar."
}

wait_longhorn_volumes_drained() {
  # Ultima conferencia antes de entregar o cluster ao `helm destroy`.
  #
  # Medicao real: volume ainda `attached` NAO impede o job longhorn-uninstall de
  # concluir — num ciclo os quatro volumes seguiam anexados e o uninstall levou
  # 2m3s mesmo assim. Entao isto nao e o que destrava o destroy; e uma checagem
  # barata que, quando os passos acima funcionam, sai de imediato, e que deixa
  # registrado o que sobrou quando nao funcionam.
  #
  # O teto e curto de proposito: se os workloads foram removidos, o Longhorn
  # libera os volumes em segundos. Esperar mais que isso e so adiar o inevitavel
  # — e uma versao anterior deste laco gastava 10 minutos sem nunca convergir.
  if ! $KUBECTL get crd volumes.longhorn.io >/dev/null 2>&1; then
    echo "==> Longhorn nao instalado; nada a drenar."
    return 0
  fi

  echo "==> Aguardando o Longhorn liberar os volumes..."
  local restantes
  for i in $(seq 1 18); do
    restantes=$($KUBECTL get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l || true)
    if [ "$restantes" -eq 0 ]; then
      echo "  Todos os volumes do Longhorn foram liberados."
      return 0
    fi
    echo "  $restantes volume(s) ainda presente(s) ($i/18); aguardando 10s..."
    sleep 10
  done

  # Nao aborta: o destino da VM e ser destruida de qualquer forma. Mas registra
  # o que sobrou, para o timeout seguinte deixar de ser um misterio.
  echo "  AVISO: ainda restam volumes no Longhorn apos 3 min; seguindo mesmo assim."
  $KUBECTL get volumes.longhorn.io -n longhorn-system 2>/dev/null || true
}

backup_minecraft_world

delete_argocd_applications

# O `sleep 30` que existia aqui era uma espera cega torcendo para o ArgoCD
# terminar a limpeza. As esperas abaixo sao por condicao observavel.
# Antes dos workloads: senao o operator recria o que for apagado.
echo "==> Removendo CRs geridas por operator..."
delete_operator_workload_crs

delete_pvc_workloads

echo "==> Deleting PVCs across all namespaces..."
# Sem o `2>/dev/null || echo "No PVCs found."` de antes: aquilo transformava um
# timeout real em uma mensagem tranquilizadora e escondia a causa do travamento.
if ! $KUBECTL delete pvc --all-namespaces --all --timeout=120s; then
  echo "  AVISO: o delete de PVCs nao concluiu no prazo."
fi

wait_longhorn_volumes_drained

# O uninstall do K3s NAO acontece aqui. Ele derruba o API server, e o
# `terragrunt destroy` dos helm releases — que roda depois deste script — precisa
# do cluster vivo para remover os releases. Com o uninstall aqui, aquele destroy
# falhava sempre com "cluster unreachable" e deixava os recursos orfaos no state.
# O uninstall foi movido para deploy.sh, apos o destroy dos helms.

echo "==> Pre-destroy cleanup complete."
