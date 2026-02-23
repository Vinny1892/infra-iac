variable "network" {}
variable "subnetwork" {}
variable "location" {}
variable "cluster_name" {}
variable "number_of_nodes" {
  default = 1
}
variable "machine_type" {
  default = "e2-medium"
}
variable "service_account_email" {}
variable "preemptible" {
  default = false
}

variable "project" {}