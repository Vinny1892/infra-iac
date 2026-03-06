variable "vpc_cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidr_blocks" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnet_cidr_blocks" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
}

variable "availability_zone" {
  description = "Availability zones for subnets"
  type        = list(string)
}

variable "extra_public_subnet_tags" {
  description = "Extra tags for public subnets"
  type        = map(string)
  default     = {}
}

variable "extra_private_subnet_tags" {
  description = "Extra tags for private subnets"
  type        = map(string)
  default     = {}
}
