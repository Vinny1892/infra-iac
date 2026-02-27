variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "network_name" {
  type    = string
  default = "vpc-gke"
}

variable "subnet_name" {
  type    = string
  default = "my-subnet"
}

variable "subnet_cidr" {
  type    = string
  default = "10.50.0.0/24"
}

variable "service_account_id" {
  type    = string
  default = "gke-service-account"
}

variable "service_account_display_name" {
  type    = string
  default = "gke service account"
}

variable "cluster_name" {
  type = string
}

variable "location" {
  type = string
}

variable "number_of_nodes" {
  type    = number
  default = 3
}

variable "machine_type" {
  type    = string
  default = "e2-medium"
}
