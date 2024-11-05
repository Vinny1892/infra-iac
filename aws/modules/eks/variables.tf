variable "region" {
  description = "A região AWS para o cluster EKS"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nome do cluster EKS"
  type        = string
  default     = "my-eks-cluster"
}

variable "cluster_version" {
  description = "Versão do Kubernetes para o cluster EKS"
  type        = string
  default     = "1.27"
}

variable "subnet_ids" {
  description = "Lista de subnets nas quais o cluster EKS será criado"
  type        = list(string)
}

variable "public_subnet_id" {
  description = "Subnet pública para lançar os workers (instâncias EC2)"
  type        = string
}

variable "worker_instance_type" {
  description = "Tipo de instância para os nós EKS"
  type        = string
  default     = "t3.medium"
}

variable "desired_capacity" {
  description = "Capacidade desejada do grupo de nós EKS"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Capacidade máxima do grupo de nós EKS"
  type        = number
  default     = 3
}

variable "min_capacity" {
  description = "Capacidade mínima do grupo de nós EKS"
  type        = number
  default     = 1
}

variable "target_group_arns" {
  description = "ARNs dos target groups para os workers do EKS"
  type        = list(string)
  default     = []
}
