variable "ami_id" {
  description = "The AMI ID to use for the instance"
  type        = string
  default     = "ami-0ae1b77caf38c2ca0" # AMI especificada
}

variable "instance_type" {
  description = "The type of instance to launch"
  type        = string
  default     = "t2.micro" # Tipo de instância padrão
}

variable "subnet_id" {
  description = "The subnet ID to launch the instance in"
  type        = string
}

variable "security_group_ids" {
  description = "A list of security group IDs to assign to the instance"
  type        = list(string)
}

variable "instance_name" {
  description = "The name to assign to the instance"
  type        = string
  default     = "MyEC2Instance"
}
