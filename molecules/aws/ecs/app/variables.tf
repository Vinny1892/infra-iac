# ── Cluster (passa cluster_id diretamente OU cluster_name para lookup) ──────
variable "cluster_id" {
  description = "ARN ou ID do ECS cluster. Mutuamente exclusivo com cluster_name."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Nome do ECS cluster para lookup. Usado quando cluster_id é null."
  type        = string
  default     = null
}

# ── Service Discovery (passa namespace_id diretamente OU namespace_name) ────
variable "namespace_id" {
  description = "ID do namespace de service discovery. Mutuamente exclusivo com namespace_name."
  type        = string
  default     = null
}

variable "namespace_name" {
  description = "Nome do namespace para lookup. Usado quando namespace_id é null."
  type        = string
  default     = null
}

variable "dns_app_name" {
  description = "Nome do serviço no service discovery"
  type        = string
}

# ── Service ──────────────────────────────────────────────────────────────────
variable "service_name" {
  type = string
}

variable "app_replicas" {
  default = 0
}

variable "enable_lb" {
  default = false
}

variable "assign_lb_with_cloud_map" {
  default = false
}

variable "vpc_id" {
  type = string
}

variable "security_groups" {}

variable "subnets" {}

variable "lb_configuration" {
  type = object({
    target_group_arn = string
    container_name   = string
    container_port   = number
  })
  default = {
    target_group_arn = ""
    container_name   = ""
    container_port   = 0
  }
}

# ── Task ─────────────────────────────────────────────────────────────────────
variable "task_name" {
  type = string
}

variable "docker_image" {
  type = string
}

variable "family" {
  type = string
}

variable "secrets" {}

variable "resources" {
  type = object({
    cpu    = number
    memory = number
  })
  default = {
    cpu    = 256
    memory = 512
  }
}

variable "port_mapping" {
  type = list(object({
    containerPort = number
    hostPort      = number
  }))
  default = [{
    containerPort = 80
    hostPort      = 80
  }]
}

variable "subnet_id" {
  type = string
}

variable "enable_efs" {
  default = false
}

variable "enable_cloud_watch" {
  default = false
}

variable "cloud_watch_configuration" {
  default = {}
}

variable "health_check_task" {
  default = {}
}

variable "efs_configuration" {
  type = object({
    root_directory   = string
    transition_to_ia = string
    mount_point = list(object({
      sourceVolume  = string
      containerPath = string
      readOnly      = bool
    }))
  })
  default = {
    root_directory   = ""
    transition_to_ia = ""
    mount_point = [{
      sourceVolume  = ""
      containerPath = ""
      readOnly      = false
    }]
  }
}

variable "commands" {
  default = []
}

variable "environment" {
  default = []
}
