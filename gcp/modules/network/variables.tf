variable "vpc_name" {}

variable "subnets" {
  type = map(object({
    region = string
    cidr = string
    name = string
  }))
}