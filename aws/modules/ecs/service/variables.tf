variable "app_replicas" {
  default = 0
}

variable "enable_lb" {
  default = false
}

variable "cluster_id" {}

variable "task_arn" {}

variable "security_groups" {}

variable "subnets" {}

variable "vpc_id" {}

variable "service_name" {}

variable "internal_dns" {
  type = object({
      dns_app_name = string
      dns_id = string
  })
}

variable "lb_configuration" {

  type = object({
    target_group_arn = string
    container_name = string
    container_port = number
  })

  default = {
    target_group_arn = ""
    container_name = ""
    container_port = 0
  }
}

variable "assign_lb_with_cloud_map" {
  default = false
}