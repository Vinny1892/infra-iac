variable "compartment_id" {
  type = string
}

variable "availability_domain" {
  type = string
}

variable "primary_subnet_id" {
  type = string
}

variable "secondary_vnic_subnet_ids" {
  type    = list(string)
  default = []
}

variable "instance_name" {
  type    = string
  default = "openstack-aio"
}

variable "ssh_port" {
  type    = number
  default = 2222
}

variable "shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  type    = number
  default = 4
}

variable "memory_in_gbs" {
  type    = number
  default = 24
}

variable "image_id" {
  type = string
}

variable "assign_public_ip" {
  type    = bool
  default = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "timezone" {
  type    = string
  default = "UTC"
}

variable "admin_user" {
  type    = string
  default = "opc"
}

variable "provider_nic_name" {
  type    = string
  default = "ens4"
}

variable "marketplace_listing_id" {
  type    = string
  default = ""
}

variable "marketplace_listing_version" {
  type    = string
  default = ""
}

variable "marketplace_eula_link" {
  type    = string
  default = ""
}

variable "marketplace_oracle_terms_link" {
  type    = string
  default = ""
}

variable "marketplace_signature" {
  type    = string
  default = ""
}

variable "marketplace_time_retrieved" {
  type    = string
  default = ""
}
