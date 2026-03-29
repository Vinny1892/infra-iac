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

variable "ssh_port" {
  description = "Porta SSH configurada no sshd_config via cloud-init"
  type        = number
  default     = 22
}

variable "assign_public_ip" {
  description = "Define se a VNIC primária recebe IP público"
  type        = bool
  default     = true
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

