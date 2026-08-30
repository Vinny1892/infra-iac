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

  if ! $KUBECTL wait -n minecraft --for=condition=complete "job/$job_name" --timeout=45m; then
    echo "ERROR: backup remoto final do Minecraft falhou; destroy cancelado para preservar o PVC."
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
    echo "  AVISO: o delete das Applications nao concluiu no prazo."
    $KUBECTL get applications -n argocd 2>/dev/null || true
  fi
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

  echo "==> Aguardando os pods liberarem os PVCs..."
  local i restantes
  for i in $(seq 1 30); do
    restantes=0
    for ns in $namespaces; do
      case "$ns" in
        longhorn-system | kube-system) continue ;;
      esac
      restantes=$((restantes + $($KUBECTL -n "$ns" get pods --no-headers 2>/dev/null | wc -l || true)))
    done
    if [ "$restantes" -eq 0 ]; then
      echo "  Todos os pods que montavam PVC foram removidos."
      return 0
    fi
    echo "  $restantes pod(s) ainda encerrando ($i/30); aguardando 5s..."
    sleep 5
  done

  echo "  AVISO: ainda ha pods ativos nos namespaces com PVC."
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
