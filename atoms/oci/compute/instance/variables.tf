variable "compartment_id" {
  description = "OCID do compartment onde a instância será criada"
  type        = string
}

variable "availability_domain" {
  description = "Availability Domain para a instância"
  type        = string
}

variable "subnet_id" {
  description = "OCID da subnet onde a instância será lançada"
  type        = string
}

variable "primary_subnet_id" {
  description = "OCID da subnet primária. Se vazio, usa subnet_id por compatibilidade."
  type        = string
  default     = ""
}

variable "secondary_vnic_subnet_ids" {
  description = "Subnets adicionais para anexar VNICs secundárias"
  type        = list(string)
  default     = []
}

variable "instance_name" {
  description = "Nome da instância"
  type        = string
  default     = "MyOCIInstance"
}

variable "shape" {
  description = "Shape da instância OCI"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  description = "Número de OCPUs (para flex shapes)"
  type        = number
  default     = 1
}

variable "memory_in_gbs" {
  description = "Memória em GB (para flex shapes)"
  type        = number
  default     = 6
}

variable "image_id" {
  description = "OCID da imagem (Oracle Linux, Ubuntu, etc.)"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Caminho para a chave pública SSH"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_authorized_keys" {
  description = "Conteúdo das chaves públicas SSH autorizadas. Quando definido, prevalece sobre ssh_public_key_path."
  type        = string
  default     = ""
}

variable "ssh_port" {
  description = "Porta SSH configurada no sshd_config via cloud-init"
  type        = number
  default     = 22
}

variable "assign_public_ip" {
  description = "Define se a VNIC primária recebe IP público efêmero. Ignorado quando reserved_public_ip_id está definido."
  type        = bool
  default     = true
}

variable "reserved_public_ip_id" {
  description = "OCID de um IP público reservado a ser anexado à VNIC primária. Quando definido, a VNIC não recebe IP efêmero."
  type        = string
  default     = ""
}

variable "reserved_public_ip_address" {
  description = "Endereço IPv4 do IP reservado. Usado no output instance_public_ip quando reserved_public_ip_id está definido."
  type        = string
  default     = ""
}

variable "user_data_base64" {
  description = "Cloud-init ou script de bootstrap em base64"
  type        = string
  default     = null
}

variable "marketplace_listing_id" {
  description = "OCID do listing do Marketplace OCI (deixe vazio para imagens padrão)"
  type        = string
  default     = ""
}

variable "marketplace_listing_version" {
  description = "Versão do listing do Marketplace OCI"
  type        = string
  default     = ""
}

variable "boot_volume_size_in_gbs" {
  description = "Tamanho do boot volume em GB. Null usa o tamanho da imagem (47 GB no Ubuntu aarch64). Mínimo 47, franquia Always Free é 200 GB somando todos os volumes."
  type        = number
  default     = null
}

variable "data_volume_size_in_gbs" {
  description = "Tamanho opcional do block volume de dados em GB. Null não cria volume adicional."
  type        = number
  default     = null
}

variable "data_volume_display_name" {
  description = "Nome do block volume de dados. Vazio usa <instance_name>-data."
  type        = string
  default     = ""
}

variable "data_volume_vpus_per_gb" {
  description = "Performance do block volume em VPUs por GB. 10 corresponde ao perfil Balanced."
  type        = number
  default     = 10
}

variable "data_volume_device" {
  description = "Caminho consistente apresentado à instância para o block volume."
  type        = string
  default     = "/dev/oracleoci/oraclevdb"
}

variable "enable_run_command_plugin" {
  description = <<-DESC
    Habilita o plugin Compute Instance Run Command do Oracle Cloud Agent.

    Atencao: pedir ENABLED aqui nao garante o plugin. Nas imagens Ubuntu aarch64
    da OCI o agente nao expoe "Compute Instance Run Command" — `oci
    instance-agent plugin list` devolve dez plugins e nenhum e esse, e qualquer
    comando responde "not present". Nao adianta policy nem agent_config: o
    plugin teria de ser instalado dentro da VM. Em Oracle Linux ele vem de
    fabrica. Confira com `oci instance-agent plugin list` antes de contar com
    ele como caminho de recuperacao.
  DESC
  type        = bool
  default     = false
}

variable "enable_bastion_plugin" {
  description = <<-DESC
    Habilita o plugin Bastion do Oracle Cloud Agent, que permite sessoes
    gerenciadas do servico OCI Bastion sem expor porta publica.

    Diferente do Run Command, este plugin e suportado nas imagens Ubuntu aarch64
    (aparece como STOPPED, nao NOT_SUPPORTED). Nao e um canal totalmente
    out-of-band: o Bastion alcanca a instancia pela rede da VCN, entao um
    iptables que barre a porta tambem barra o Bastion. Para falha real de rede
    no host, o unico caminho e o console serial.
  DESC
  type        = bool
  default     = false
}
