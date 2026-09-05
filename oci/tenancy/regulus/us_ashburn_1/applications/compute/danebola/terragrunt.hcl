include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "provider" {
  path = find_in_parent_folders("_provider.hcl")
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("_locals.hcl"))

  # Mesma porta definitiva da vm-regulus, e pelo mesmo motivo. Aqui ela so
  # libera o iptables: o sshd nasce na 22 e a troca acontece no harden_ssh_port
  # do deploy.sh, validando de fora.
  #
  # Diferenca que importa: esta VM NAO tem honeypot na 22. Na vm-regulus a 22
  # fica ocupada pelo Cowrie depois do deploy; aqui ela fica livre, entao a
  # troca de porta e a unica coisa que a tira de exposicao direta.
  ssh_port = 62222
}

dependency "vcn" {
  config_path = "../../../network/vcn"

  mock_outputs = {
    subnet_public = [{ id = "ocid1.subnet.mock", availability_domain = "jnRJ:US-ASHBURN-AD-1" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../atoms/oci/compute/instance"
}

inputs = {
  compartment_id      = local.region_vars.locals.compartment_id
  availability_domain = dependency.vcn.outputs.subnet_public[0].availability_domain
  subnet_id           = dependency.vcn.outputs.subnet_public[0].id
  instance_name       = "danebola"
  shape               = "VM.Standard.A1.Flex"

  # 1 OCPU / 10 GB: o node escravo do k3s, dimensionado pelo Minecraft.
  #
  # Quem manda no tamanho e o `requests: 7Gi` do Minecraft, nao o consumo real
  # dele (pico medido de 5,7 GiB em 19h) — o scheduler reserva pelo request.
  # Somando o overhead do node (agent + DaemonSets 0,48 + instance-manager 0,33
  # + SO ~= 1,8 GiB), fecha 8,8 de 10.
  #
  # O limite do Minecraft e 8Gi. Se ele algum dia encostar nele, sobra 1,2 GiB
  # para o sistema — apertado. O request inflado (7Gi para 5,7 GiB de pico) e o
  # que come a folga; baixa-lo para 6Gi devolveria 1 GiB, mas mexer em recurso
  # de aplicacao nao fazia parte do split.
  ocpus         = 1
  memory_in_gbs = 10

  image_id            = local.region_vars.locals.image_id
  ssh_authorized_keys = run_cmd("--terragrunt-quiet", "op", "read", "op://Personal/Pessoal/public key")

  # Disco do Longhorn, igual ao da vm-regulus de proposito: com 2 replicas o
  # agendamento compara espaco entre os discos, e assimetria produz decisao
  # dificil de prever. Formatado e montado em /var/lib/longhorn pelo
  # configure-regulus-host.sh, que o deploy.sh roda nas duas VMs.
  data_volume_size_in_gbs  = 100
  data_volume_display_name = "danebola-longhorn"
  data_volume_vpus_per_gb  = 10
  data_volume_device       = "/dev/oracleoci/oraclevdb"

  # Sem IP reservado: esta VM nao recebe trafego de entrada de ninguem.
  # O DNS aponta para o IP da vm-regulus, o Traefik de la encaminha, e o
  # kube-proxy entrega no pod aqui. Um IP efemero basta para a saida e para o
  # SSH do deploy.
  enable_run_command_plugin = true
  enable_bastion_plugin     = true

  # O user_data prepara o host e PARA AI: nao instala k3s.
  #
  # O agent precisa do token do server, que so existe depois de o server subir.
  # Passa-lo por aqui exigiria coloca-lo em user_data, que fica legivel em
  # metadata de instancia para qualquer processo na VM (169.254.169.254) e para
  # qualquer principal com leitura na instancia. Entao o join acontece por SSH,
  # no deploy.sh, com o token lido do server tambem por SSH — mesmo padrao do
  # harden_ssh_port: acao pos-boot, fora do cloud-init.
  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/danebola-host-init.log) 2>&1
    set -euo pipefail

    SSH_PORT="${local.ssh_port}"

    # O primeiro download falha se o cloud-init comecar antes de haver rota de
    # saida, e o set -e derruba o script inteiro — a VM sobe RUNNING e sem nada
    # preparado, sem erro visivel em lugar nenhum.
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

    # Quem disputa o lock do apt no primeiro boot NAO e o apt-daily: e o snap do
    # Oracle Cloud Agent, que roda `/bin/apt update` sozinho quando a instancia
    # sobe. Desarmar timer nenhum resolve, e DPkg::Lock::Timeout nao cobre o
    # lock de /var/lib/apt/lists. A unica saida confiavel e insistir.
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

    echo "==> Instalando pre-requisitos do Longhorn"
    apt_retry "update" apt-get -o DPkg::Lock::Timeout=600 update -y
    apt_retry "open-iscsi nfs-common" apt-get -o DPkg::Lock::Timeout=600 install -y open-iscsi nfs-common
    systemctl enable --now iscsid

    # A imagem Ubuntu da OCI fecha a chain INPUT com REJECT, entao liberar na
    # security list nao basta: sem estas regras a porta responde
    # "No route to host", sintoma indistinguivel de firewall de nuvem.
    echo "==> Abrindo portas no iptables"
    iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    iptables -I INPUT -p tcp --dport 22    -j ACCEPT
    iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
    # 9100: node-exporter (DaemonSet hostNetwork). O vmagent raspa de dentro de
    # um pod na vm-regulus; sem esta regra o trafego cross-node morre no REJECT
    # final do INPUT da imagem e o alvo fica "down" no VictoriaMetrics — foi o
    # sintoma de 05/09/2026: pod Running/Ready, localhost:9100 respondendo 200,
    # scrape sempre falhando.
    iptables -I INPUT -p tcp --dport 9100 -j ACCEPT
    iptables -I INPUT -p udp --dport 8472  -j ACCEPT

    # 80, 443 e 25565 ficam FECHADAS aqui de proposito, ao contrario da
    # vm-regulus. O Traefik e DaemonSet e vai subir nesta VM tambem, com
    # hostPort nessas portas — mas quem deve receber trafego de fora e so o IP
    # reservado da vm-regulus. A security list e por subnet e abre essas portas
    # para as duas VMs; e este iptables que faz a diferenciacao por host.
    apt_retry "iptables-persistent" apt-get -o DPkg::Lock::Timeout=600 install -y iptables-persistent -q
    netfilter-persistent save

    echo "==> Host pronto. O k3s agent ainda NAO esta instalado."
    echo "    O join acontece por SSH, no deploy.sh, com o token do server."
  EOF
  )
}
