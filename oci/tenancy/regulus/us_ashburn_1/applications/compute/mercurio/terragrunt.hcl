include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))

  # Mesma porta definitiva de SSH da vm-regulus, pelo mesmo motivo: a 22 fica
  # exposta a 0.0.0.0/0 e porta alta corta varredura automatizada. Aqui ela so
  # libera o iptables — o sshd nasce na 22 e a troca acontece de fora, com prova
  # de alcancabilidade, como no harden_ssh_port do deploy.sh.
  #
  # ATENCAO: esta VM nao tem honeypot na 22. Ao contrario da vm-regulus, deixar
  # o sshd na 22 aqui nao entrega nada a um atacante alem do proprio sshd — mas
  # tambem nao ha sensor para avisar que alguem tentou.
  ssh_port = 62222

  # UID/GID que a imagem do agente usa via s6-overlay. Os nomes HERMES_UID e
  # HERMES_GID sao da imagem upstream (nousresearch/hermes-agent) e continuam
  # assim de proposito: renomea-los aqui esconderia a correspondencia com o que
  # o container espera. O diretorio de dados precisa nascer com esse dono,
  # senao o container nao escreve em /opt/data.
  hermes_uid = 10000
  hermes_gid = 10000
}

dependency "vcn" {
  config_path = "../../../network/vcn"

  mock_outputs = {
    subnet_public = [{ id = "ocid1.subnet.mock", availability_domain = "jnRJ:US-ASHBURN-AD-1" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "reserved_ip" {
  config_path = "../../../network/reserved_ip_mercurio"

  mock_outputs = {
    public_ip_id      = "ocid1.publicip.mock"
    public_ip_address = "203.0.113.11"
  }
  # Mesma lista da vm-regulus, e pelo mesmo motivo: sem os mocks em
  # init/output/destroy, a falha em resolver estes outputs derruba o parse de
  # TODO o bloco dependency — inclusive o da vcn — e impede destruir a VM.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "output", "destroy"]
}

terraform {
  source = "../../../../../../../atoms/oci/compute/instance"
}

inputs = {
  compartment_id      = local.region_vars.locals.compartment_id
  availability_domain = dependency.vcn.outputs.subnet_public[0].availability_domain
  subnet_id           = dependency.vcn.outputs.subnet_public[0].id
  instance_name       = "mercurio"
  shape               = "VM.Standard.A1.Flex"

  # 1 OCPU / 6 GB dos 4 OCPU / 24 GB da franquia Always Free de A1. O resto vai
  # para a vm-regulus (2/8, control plane) e a danebola (1/10, que hospeda o
  # Minecraft e seus 7 GiB de request). A soma fecha exatamente a franquia.
  #
  # Dimensionado com folga de proposito: o pico medido do mercurio em 19h foi
  # 690 Mi. O que consome memoria aqui nao e o agente, sao os containers que ele
  # cria para executar comandos (TERMINAL_CONTAINER_MEMORY=1024 cada).
  ocpus         = 1
  memory_in_gbs = 6

  image_id            = local.region_vars.locals.image_id
  ssh_authorized_keys = run_cmd("--terragrunt-quiet", "op", "read", "op://Personal/Pessoal/public key")

  # Sem volume de dados: os 10 GiB de /opt/data cabem no boot volume de 47 GB,
  # que tem folga (o SO ocupa ~5 GB numa imagem nova). Um volume dedicado
  # custaria franquia de block storage sem entregar nada — e a franquia esta
  # apertada, ver docs do split.
  #
  # A contrapartida e que /opt/data vive no boot volume: nao ha como desanexar e
  # reanexar o dado noutra VM sem copiar. Como o dado NAO e reconstruivel a
  # partir do repositorio (auth.json do Codex, sessoes e skills), o backup
  # remoto deixa de ser opcional — ele e o unico caminho de volta.

  # Run Command fica pedido mas o agente do Ubuntu aarch64 nao entrega o plugin
  # nesta imagem; o Bastion, sim, e e o canal que nao depende de porta publica.
  enable_run_command_plugin = true
  enable_bastion_plugin     = true

  reserved_public_ip_id      = dependency.reserved_ip.outputs.public_ip_id
  reserved_public_ip_address = dependency.reserved_ip.outputs.public_ip_address

  # O user_data prepara a VM e PARA AI: instala Docker, abre o firewall e cria o
  # diretorio de dados. Ele nao sobe o mercurio, de proposito.
  #
  # O motivo e que o mercurio precisa de dois segredos (basic auth do dashboard e
  # token do bot do Telegram) e user_data NAO e lugar para segredo: ele fica
  # legivel em metadata da instancia, acessivel por qualquer processo na VM via
  # 169.254.169.254 e por qualquer principal com permissao de leitura na
  # instancia. Dentro do cluster isso era resolvido pelo External Secrets
  # Operator; aqui o equivalente e injetar apenas o token de service account do
  # 1Password por SSH, apos o boot, e deixar o `op` buscar o resto — um segredo
  # de fora em vez de dois, mesmo principio do onepassword-token do cluster.
  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/mercurio-host-init.log) 2>&1
    set -euo pipefail

    SSH_PORT="${local.ssh_port}"
    PUBLIC_IP="${dependency.reserved_ip.outputs.public_ip_address}"
    HERMES_UID="${local.hermes_uid}"
    HERMES_GID="${local.hermes_gid}"

    echo "==> IP publico reservado, injetado pelo Terraform: $PUBLIC_IP"

    # O IP reservado e anexado a VNIC logo apos a criacao da instancia, o que
    # pode ocorrer depois do cloud-init comecar. Sem esperar a rota de saida, o
    # primeiro download falha e o set -e derruba o script inteiro.
    echo "==> Aguardando conectividade de saida"
    for i in $(seq 1 90); do
      if curl -sf -m 5 -o /dev/null https://download.docker.com; then
        echo "  rede pronta na tentativa $i"
        break
      fi
      echo "  tentativa $i/90 — sem rota de saida ainda, aguardando 5s..."
      sleep 5
    done
    curl -sf -m 10 -o /dev/null https://download.docker.com || {
      echo "ERRO: sem conectividade de saida apos 90 tentativas"
      exit 1
    }

    # Quem disputa o lock do apt no primeiro boot NAO e o apt-daily: e o snap do
    # Oracle Cloud Agent, que roda `/bin/apt update` por conta propria assim que
    # a instancia sobe. Ele nao esta sob nosso controle, entao desarmar timer
    # nenhum resolve, e `DPkg::Lock::Timeout` nao cobre o lock de
    # /var/lib/apt/lists. A unica saida confiavel e insistir.
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

    # docker.io + docker-compose-v2 dos repositorios do Ubuntu, e nao o repo
    # oficial do Docker, de proposito: adicionar repo de terceiro no cloud-init
    # exige baixar chave GPG, escrever sources.list e um apt-get update extra —
    # tres passos a mais num lugar onde falha silenciosa custa a VM. As versoes
    # que importam aqui estao nas imagens dos containers (o DinD e pinado no
    # compose), nao no daemon do host.
    echo "==> Instalando Docker"
    apt_retry "update" apt-get -o DPkg::Lock::Timeout=600 update -y
    apt_retry "docker" apt-get -o DPkg::Lock::Timeout=600 install -y docker.io docker-compose-v2
    systemctl enable --now docker

    # Diretorio de dados do mercurio, com o dono que o s6-overlay espera.
    echo "==> Preparando /opt/data (dono $HERMES_UID:$HERMES_GID)"
    mkdir -p /opt/data
    chown "$HERMES_UID:$HERMES_GID" /opt/data
    chmod 0750 /opt/data

    # A imagem Ubuntu da OCI fecha a chain INPUT com um REJECT, entao liberar na
    # security list nao basta: sem estas regras a porta responde
    # "No route to host" e o sintoma e indistinguivel de firewall de nuvem.
    # A 22 ja vem liberada na imagem, mas fica explicita porque ela passa a ser
    # a porta de recuperacao quando a troca para $SSH_PORT falha.
    echo "==> Abrindo portas no iptables"
    iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    iptables -I INPUT -p tcp --dport 22  -j ACCEPT
    iptables -I INPUT -p tcp --dport 80  -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    apt_retry "iptables-persistent" apt-get -o DPkg::Lock::Timeout=600 install -y iptables-persistent -q
    netfilter-persistent save

    # O dashboard (9119) e o gateway (8642) NAO sao abertos: quem atende de fora
    # e o proxy reverso na 443, no mesmo host. Publicar 9119 direto contornaria
    # o proxy e, com ele, a primeira camada de autenticacao.

    echo "==> Host pronto. O mercurio ainda NAO esta rodando."
    echo "    Falta injetar o token do 1Password e subir o compose — ver docs."
  EOF
  )
}
