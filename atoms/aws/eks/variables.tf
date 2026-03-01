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

variable "max_pods_per_node" {
  description = "Maximum number of pods per node (use higher values with prefix delegation)"
  type        = number
  default     = 110
}
