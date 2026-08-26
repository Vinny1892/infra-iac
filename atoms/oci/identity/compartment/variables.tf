variable "parent_compartment_id" {
  description = "OCID do compartment pai. Use o OCID da tenancy para criar no primeiro nível."
  type        = string
}

variable "name" {
  description = "Nome do compartment. Único dentro do pai."
  type        = string
}

variable "description" {
  description = "Descrição do compartment"
  type        = string
}

variable "enable_delete" {
  description = "Se true, destruir o recurso apaga o compartment. Padrão false: o Terraform apenas o esquece, evitando exclusão acidental de tudo que ele contém."
  type        = bool
  default     = false
}

variable "freeform_tags" {
  description = "Tags livres"
  type        = map(string)
  default     = {}
}
