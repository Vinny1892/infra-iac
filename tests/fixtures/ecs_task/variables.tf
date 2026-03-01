variable "task_name" {
  type    = string
  default = "test-task"
}

variable "docker_image" {
  type    = string
  default = "nginx:latest"
}

variable "family" {
  type    = string
  default = "test-family"
}

variable "secrets" {
  type    = list(any)
  default = []
}

variable "subnet_id" {
  type    = string
  default = "subnet-mock123"
}
