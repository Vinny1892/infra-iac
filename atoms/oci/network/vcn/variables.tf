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

variable "ssh_allowed_cidr" {
  description = "CIDR permitido para acesso SSH"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_port" {
  description = "Porta SSH"
  type        = number
  default     = 22
}

variable "additional_ingress_rules" {
  description = "Regras extras de ingress para a security list padrão"
  type = list(object({
    source      = string
    protocol    = string
    description = optional(string)
    stateless   = optional(bool, false)
    tcp_options = optional(object({
      min = number
      max = number
    }))
    udp_options = optional(object({
      min = number
      max = number
    }))
    icmp_options = optional(object({
      type = number
      code = optional(number)
    }))
  }))
  default = []
}

variable "additional_egress_rules" {
  description = "Regras extras de egress para a security list padrão"
  type = list(object({
    destination = string
    protocol    = string
    description = optional(string)
    stateless   = optional(bool, false)
    tcp_options = optional(object({
      min = number
      max = number
    }))
    udp_options = optional(object({
      min = number
      max = number
    }))
    icmp_options = optional(object({
      type = number
      code = optional(number)
    }))
  }))
  default = []
}
