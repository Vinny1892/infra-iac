output "cluster_endpoint" {
  description = "Endpoint do cluster EKS"
  value       = aws_eks_cluster.eks_cluster.endpoint
}

output "worker_iam_role" {
  description = "IAM Role dos nós EKS (workers)"
  value       = aws_iam_role.eks_worker_role.arn
}

output "eks_cluster_security_group_id" {
  description = "O ID do security group do cluster EKS"
  value       = aws_eks_cluster.eks_cluster.vpc_config[0].cluster_security_group_id
}
