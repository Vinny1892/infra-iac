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
