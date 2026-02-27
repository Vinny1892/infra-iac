variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "k3s_token" {
  type      = string
  sensitive = true
  default   = "k3s-seila"
}

variable "masters_count" {
  type    = number
  default = 2
}

variable "rds_password" {
  type      = string
  sensitive = true
  default   = "password"
}
