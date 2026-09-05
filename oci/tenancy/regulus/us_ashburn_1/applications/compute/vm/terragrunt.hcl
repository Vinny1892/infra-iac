include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars  = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))
  k3s_dns_name = "k3s.vinny.dev.br"
  k3s_version  = "v1.36.4+k3s1"

  # Porta definitiva do SSH. Aqui ela serve so para liberar o iptables: o sshd
  # nasce na 22 e quem faz a troca e o harden_ssh_port do deploy.sh, no fim do
  # deploy. Precisa bater com ssh_port da unit network/vcn e com
  # HARDENED_SSH_PORT do deploy.sh.
  ssh_port = 62222
}

dependency "vcn" {
  config_path = "../../../network/vcn"

  mock_outputs = {
    subnet_public = [{ id = "ocid1.subnet.mock", availability_domain = "jnRJ:US-ASHBURN-AD-1" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "reserved_ip" {
  config_path = "../../../network/reserved_ip"

  mock_outputs = {
    public_ip_id      = "ocid1.publicip.mock"
    public_ip_address = "203.0.113.10"
  }
  # destroy/output/init tambem precisam dos mocks: enquanto a unit reserved_ip
  # nao tiver state, a falha em resolver estes outputs derruba o parse de TODO
  # o bloco dependency — inclusive o da vcn — e impede destruir a VM.
  # Os mocks so entram quando nao ha outputs reais; com a unit aplicada, o valor
  # verdadeiro prevalece.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "output", "destroy"]
}

terraform {
  source = "../../../../../../../atoms/oci/compute/instance"
}

# O user_data fica em inputs (e nao em locals) porque precisa do endereco vindo
# de dependency.reserved_ip, e locals do Terragrunt sao avaliados antes das
# dependencies.
inputs = {
  compartment_id      = local.region_vars.locals.compartment_id
  availability_domain = dependency.vcn.outputs.subnet_public[0].availability_domain
  subnet_id           = dependency.vcn.outputs.subnet_public[0].id
  instance_name       = "vm-regulus"
  shape               = "VM.Standard.A1.Flex"

  # 2 OCPU / 8 GB apos o split. Esta VM deixou de ser o cluster inteiro e virou
  # so o control plane mais a plataforma (argocd, monitoring, longhorn,
  # cert-manager, ESO, metallb, traefik, postgres, cowrie, whoami). O Minecraft,
  # que pede 7 GiB de request, mudou para a danebola — nao cabe aqui de
  # proposito, e e o request dele que garante que ele nao volte por acidente.
  #
  # Conferido contra pico medido de 19h antes do split: overhead do node 3,2 GiB
  # (k3s server 2,07 + DaemonSets 0,48 + instance-manager 0,33 + SO) mais ~3,5
  # GiB da plataforma = 6,7 de 8. Folga de 1,3 GiB.
  #
  # A soma das tres VMs (2/8 aqui, 1/10 na danebola, 1/6 na hermes) fecha
  # exatamente os 4 OCPU / 24 GB da franquia Always Free de A1.
  ocpus               = 2
  memory_in_gbs       = 8
  image_id            = local.region_vars.locals.image_id
  ssh_authorized_keys = run_cmd("--terragrunt-quiet", "op", "read", "op://Personal/Pessoal/public key")

  # Volume dedicado ao Longhorn, formatado e montado em /var/lib/longhorn pelo
  # configure-regulus-host.sh (via UUID no fstab), nao pelo cloud-init.
  #
  # ATENCAO: o split estourou a franquia de block storage. Boot (47) + dados
  # (100) desta VM, mais os mesmos 147 GB da danebola, mais 47 GB de boot da
  # hermes, dao 341 GB — 141 GB acima dos 200 GB gratuitos. E consequencia
  # aceita de ter Longhorn com 2 replicas, que e o unico jeito de o cluster
  # sobreviver a perda de um node com os dados intactos.
  #
  # Os 100 GB aqui e na danebola sao iguais de proposito: o Longhorn agenda
  # replicas comparando espaco entre os discos, e disco assimetrico produz
  # decisao de agendamento dificil de prever.
  data_volume_size_in_gbs  = 100
  data_volume_display_name = "vm-regulus-longhorn"
  data_volume_vpus_per_gb  = 10
  data_volume_device       = "/dev/oracleoci/oraclevdb"
  # Run Command fica pedido, mas o agente do Ubuntu aarch64 nao entrega o
  # plugin — ver a descricao da variavel no atom. O Bastion, esse sim, e
  # suportado, e e o canal de acesso que nao depende de porta publica.
  enable_run_command_plugin = true
  enable_bastion_plugin     = true

  reserved_public_ip_id      = dependency.reserved_ip.outputs.public_ip_id
  reserved_public_ip_address = dependency.reserved_ip.outputs.public_ip_address

  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/k3s-install.log) 2>&1
    set -euo pipefail

    K3S_VERSION="${local.k3s_version}"
    DNS_NAME="${local.k3s_dns_name}"
    PUBLIC_IP="${dependency.reserved_ip.outputs.public_ip_address}"

    echo "==> IP publico reservado, injetado pelo Terraform: $PUBLIC_IP"

    SSH_PORT="${local.ssh_port}"

    # A VM nasce com o sshd na 22 de proposito. Mover a porta aqui foi tentado e
    # deu errado: a VM subiu com K3s funcionando e ficou inacessivel por SSH nas
    # duas portas — a 22 rejeitada (ninguem escutando) e a 62222 rejeitada pelo
    # iptables ou escutando so em IPv6; a causa nunca foi isolada, porque
    # diagnosticar exigia justamente o acesso que havia se perdido. Sem o plugin
    # Compute Instance Run Command nesta imagem, o unico caminho de volta era
    # console serial, e a VM teve de ser recriada.
    #
    # A licao nao e "o script estava com bug", e sim que cloud-init e o lugar
    # errado para essa mudanca: aqui nao ha como testar se a porta nova ficou
    # alcancavel DE FORA, e `ss -lnt` so prova que algo escuta localmente. Quem
    # troca a porta agora e o harden_ssh_port do deploy.sh, depois do cluster de
    # pe, validando de fora e revertendo para a 22 se a validacao falhar.

    # O IP reservado e anexado a VNIC logo apos a criacao da instancia, o que
    # pode ocorrer depois do cloud-init comecar. Sem esperar a rota de saida,
    # o primeiro download falha e o set -e derruba o script inteiro.
    echo "==> Aguardando conectividade de saida"
    for i in $(seq 1 90); do
      if curl -sf -m 5 -o /dev/null https://get.k3s.io; then
        echo "  rede pronta na tentativa $i"
        break
      fi
      echo "  tentativa $i/90 — sem rota de saida ainda, aguardando 5s..."
      sleep 5
    done
    curl -sf -m 10 -o /dev/null https://get.k3s.io || {
      echo "ERRO: sem conectividade de saida apos 90 tentativas"
      exit 1
    }

    # O Ubuntu dispara apt-daily/unattended-upgrades no primeiro boot e segura o
    # lock do apt. Sem tratar isso, o apt-get abaixo morre com "Could not get
    # lock /var/lib/apt/lists/lock" e o set -e derruba o user_data inteiro antes
    # do K3s ser instalado — a VM sobe RUNNING mas sem cluster nenhum.
    # Quem disputa o lock do apt no primeiro boot NAO e o apt-daily: e o snap do
    # Oracle Cloud Agent, que roda `/bin/apt update` por conta propria assim que
    # a instancia sobe. No journal aparece como:
    #   sudo[...]: snap_daemon : PWD=/var/snap/oracle-cloud-agent/... COMMAND=/bin/apt update
    # Ele nao esta sob nosso controle, entao desarmar timer nenhum resolve. E
    # `DPkg::Lock::Timeout` nao cobre o lock de /var/lib/apt/lists, justamente o
    # disputado pelo `apt-get update` — por isso a falha era imediata.
    # A unica saida confiavel e insistir ate o lock ser liberado.
    systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

    apt_retry() {
      local desc="$1"; shift
      local i
      for i in $(seq 1 60); do
        if "$@"; then
          return 0
        fi
        echo "  apt ocupado em '$desc' (tentativa $i/60); aguardando 10s..."
        sleep 10
      done
      echo "ERRO: '$desc' nao concluiu apos 10 min aguardando o lock do apt."
      exit 1
    }

    echo "==> Instalando pre-requisitos Longhorn"
    apt_retry "update" apt-get -o DPkg::Lock::Timeout=600 update -y
    apt_retry "open-iscsi nfs-common" apt-get -o DPkg::Lock::Timeout=600 install -y open-iscsi nfs-common
    systemctl enable --now iscsid

    echo "==> Abrindo portas no iptables"
    # A imagem Ubuntu da OCI fecha a chain INPUT com um REJECT: liberar na
    # security list nao basta, a instancia tambem filtra.
    #
    # A porta alta e liberada aqui, ainda sem ninguem escutando nela. Isso deixa
    # o firewall pronto antes de o harden_ssh_port mexer no sshd, e serve de
    # diagnostico: com a regra ativa e o sshd ainda na 22, um teste na porta
    # alta deve responder "connection refused". Se responder "no route to host"
    # (ICMP host-prohibited), quem esta barrando e o iptables, e o harden aborta
    # antes de tocar no sshd.
    iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    # A 22 ja vem liberada na imagem, mas a regra e explicitada porque ela passa
    # a servir o honeypot depois que o sshd sai — quem ler isto precisa saber
    # que a porta continua aberta de proposito.
    iptables -I INPUT -p tcp --dport 22   -j ACCEPT
    iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
    iptables -I INPUT -p tcp --dport 80   -j ACCEPT
    iptables -I INPUT -p tcp --dport 443  -j ACCEPT
    iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
    iptables -I INPUT -p udp --dport 8472  -j ACCEPT
    apt_retry "iptables-persistent" apt-get -o DPkg::Lock::Timeout=600 install -y iptables-persistent -q
    netfilter-persistent save

    # MTU do overlay: a VCN da OCI negocia jumbo frames (MTU 8950) na enp0s6, e
    # o flannel herda esse valor para flannel.1, cni0 e veths. Mas o VXLAN
    # encapsula em UDP e a rede entrega no maximo ~1450 bytes de payload —
    # pacote maior morre silenciosamente (sem ICMP, sem log). Sintoma real em
    # 05/09/2026, pos-split das VMs: TCP conectava, handshake TLS travava, todo
    # pod->API expirava (dial tcp 10.43.0.1:443: i/o timeout) e os controllers
    # perdiam leader-election em cascata (vm-operator, cainjector, cnpg, CSI).
    # Ping pequeno passava; DF ping >1400 sobre o overlay nao. --flannel-mtu
    # corrige flannel.1, cni0 e os veths de forma consistente desde o boot.
    echo "==> Instalando K3s $K3S_VERSION"
    # --node-external-ip: REMOVIDO. Com IP reservado anexado a VNIC, o k3s nao
    # descobre sozinho o endereco externo — mas o unico consumidor dessa flag
    # (CronJob traefik-patch-external-ip) foi removido ha tempos. Pior: ela
    # fazia o endpoint do service `kubernetes` ser o IP PUBLICO, forcando todo
    # pod->API a hairpin pela borda da OCI em vez de falar com o node vizinho
    # pelo privado. O ExternalIP do node e metadado; se voltar a ser preciso,
    # volta como anotacao, nao como endereco de endpoint.
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
      --write-kubeconfig-mode 644 \
      --disable=traefik \
      --disable=servicelb \
      --flannel-mtu 1450 \
      --tls-san "$PUBLIC_IP" \
      --tls-san "$DNS_NAME"

    echo "==> Aguardando K3s ficar Ready"
    until /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q " Ready"; do
      echo "  aguardando..."
      sleep 5
    done

    echo "==> K3s pronto"
    /usr/local/bin/kubectl get nodes
  EOF
  )
}
