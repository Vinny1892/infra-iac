variable "compartment_id" {
  description = "OCID do compartment onde os recursos serão criados"
  type        = string
}

variable "vcn_cidr_block" {
  description = "CIDR block para a VCN"
  type        = string
  default     = "10.20.0.0/16"
}

variable "vcn_name" {
  description = "Nome da VCN"
  type        = string
  default     = "MainVCN"
}

variable "public_subnet_cidr_blocks" {
  description = "CIDR blocks para subnets públicas"
  type        = list(string)
}

variable "private_subnet_cidr_blocks" {
  description = "CIDR blocks para subnets privadas"
  type        = list(string)
}

variable "availability_domains" {
  description = "Lista de Availability Domains para distribuir subnets"
  type        = list(string)
}
