variable "subnet_id" {
  type    = string
  default = "subnet-mock123"
}

variable "security_group_ids" {
  type    = list(string)
  default = ["sg-mock123"]
}

variable "instance_name" {
  type    = string
  default = "test-ec2"
}
