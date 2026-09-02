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

  # SSH real fora da 22: a 22 fica livre para o honeypot (Cowrie, hostPort 22).
  # Precisa bater com ssh_port da unit network/vcn e com SSH_PORT do deploy.sh.
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
  ocpus               = 4
  memory_in_gbs       = 24
  image_id            = local.region_vars.locals.image_id
  ssh_authorized_keys = run_cmd("--terragrunt-quiet", "op", "read", "op://Personal/Pessoal/public key")

  # Volume dedicado ao Longhorn. Boot (47 GB) + dados (100 GB) permanecem
  # abaixo dos 200 GB combinados da franquia Always Free desta tenancy.
  data_volume_size_in_gbs   = 100
  data_volume_display_name  = "vm-regulus-longhorn"
  data_volume_vpus_per_gb   = 10
  data_volume_device        = "/dev/oracleoci/oraclevdb"
  enable_run_command_plugin = true

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

    # Antes de qualquer coisa que dependa de rede: se o K3s falhar mais adiante,
    # o acesso administrativo ja esta de pe na porta nova. Importa mais aqui do
    # que pareceria, porque o plugin Compute Instance Run Command nao e exposto
    # nesta instancia — nao ha canal de recuperacao fora do SSH.
    #
    # Drop-in em vez de sed no sshd_config: o arquivo principal do Ubuntu comeca
    # com Include /etc/ssh/sshd_config.d/*.conf, e o cloud-image ja despeja
    # ajustes proprios ali. Editar o arquivo principal a mao entra em disputa
    # com esses drop-ins.
    echo "==> Movendo o sshd para a porta $SSH_PORT"
    install -d -m 755 /etc/ssh/sshd_config.d
    # printf, e nao heredoc: este script inteiro ja vive dentro de um heredoc
    # do HCL. Um heredoc aninhado exigiria tabs de indentacao, e o <<- do HCL
    # corta a menor indentacao comum do bloco — com um tab no meio, ele passaria
    # a cortar 1 caractere em vez de 4 e o shebang da primeira linha sairia
    # indentado, fazendo o cloud-init ignorar o script todo.
    printf '%s\n' \
      "Port $SSH_PORT" \
      "PermitRootLogin no" \
      "PasswordAuthentication no" \
      "KbdInteractiveAuthentication no" \
      "PubkeyAuthentication yes" \
      > /etc/ssh/sshd_config.d/99-regulus.conf

    # Ubuntu 24.04 entrega o sshd com socket activation: quando ssh.socket esta
    # habilitado, quem decide a porta e o ListenStream da unit, e a diretiva
    # Port do sshd_config e simplesmente ignorada. Sem este override, o servico
    # continuaria na 22 — que a partir daqui pertence ao honeypot.
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      echo "  ssh.socket ativo: sobrescrevendo ListenStream"
      install -d -m 755 /etc/systemd/system/ssh.socket.d
      # ListenStream= vazio primeiro: sem essa linha o systemd soma a porta nova
      # a 22 herdada da unit original, em vez de substitui-la.
      printf '%s\n' "[Socket]" "ListenStream=" "ListenStream=$SSH_PORT" \
        > /etc/systemd/system/ssh.socket.d/override.conf
      systemctl daemon-reload
      systemctl restart ssh.socket
    else
      sshd -t
      systemctl restart ssh
    fi

    echo "==> Conferindo que o sshd respondeu na porta $SSH_PORT"
    for i in $(seq 1 30); do
      if ss -lnt | grep -q ":$SSH_PORT "; then
        echo "  sshd escutando em $SSH_PORT"
        break
      fi
      echo "  tentativa $i/30 — sshd ainda nao escuta em $SSH_PORT, aguardando 2s..."
      sleep 2
    done
    ss -lnt | grep -q ":$SSH_PORT " || {
      echo "ERRO: sshd nao subiu na porta $SSH_PORT"
      exit 1
    }

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
    iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    # A 22 ja vem liberada na imagem, mas a regra e explicitada porque agora ela
    # serve o honeypot, nao o sshd — quem ler isto depois precisa saber que a
    # porta continua aberta de proposito.
    iptables -I INPUT -p tcp --dport 22   -j ACCEPT
    iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
    iptables -I INPUT -p tcp --dport 80   -j ACCEPT
    iptables -I INPUT -p tcp --dport 443  -j ACCEPT
    iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
    iptables -I INPUT -p udp --dport 8472  -j ACCEPT
    apt_retry "iptables-persistent" apt-get -o DPkg::Lock::Timeout=600 install -y iptables-persistent -q
    netfilter-persistent save

    echo "==> Instalando K3s $K3S_VERSION"
    # --node-external-ip: a VNIC nao recebe mais IP publico efemero (o endereco
    # vem do IP reservado, anexado apos a criacao da instancia), entao o k3s nao
    # descobre sozinho o endereco externo e o node ficaria sem ExternalIP.
    #
    # O CronJob traefik-patch-external-ip, que era o consumidor citado aqui, foi
    # removido: com o Service do Traefik em LoadBalancer, quem publica o IP no
    # status do Ingress e o MetalLB, nao `spec.externalIPs`. A flag permanece
    # porque o ExternalIP do node e metadado legitimo — mas nenhum consumidor
    # atual dele foi reconfirmado.
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
      --write-kubeconfig-mode 644 \
      --disable=traefik \
      --disable=servicelb \
      --node-external-ip "$PUBLIC_IP" \
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
