variable "enable_cloud_watch" {
  default = false
}

variable "enable_efs" {
  default = false
}

variable "subnet_id" {}

variable "cloud_watch_configuration" {
  type = object({
    region  = string
    logName = string
  })
  default = {
    region  = ""
    logName = ""
  }
}

variable "task_name" {
  type        = string
  default     = ""
  description = "description"
  nullable    = false
}

variable "docker_image" {
  type     = string
  nullable = false
}
variable "environment" {
  default = []
}

variable "port_mapping" {
  type = list(object({
    containerPort = number
    hostPort      = number
  }))
  default = [
    {
      containerPort = 80
      hostPort      = 80
    }
  ]
  description = "description"
  nullable    = false
}


variable "secrets" {
  nullable = false
}

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
variable "family" {

}

variable "health_check_task" {
  default = {}
}

variable "efs_configuration" {
  type = object({
    root_directory   = string
    transition_to_ia = string
    mount_point = list(object({
      sourceVolume  = string,
      containerPath = string,
      readOnly      = bool
    }))
  })
  default = {
    root_directory   = ""
    transition_to_ia = ""
    mount_point = [{
      sourceVolume  = "",
      containerPath = "",
      readOnly      = false
    }]
  }
}

variable "commands" {
  default = []
}