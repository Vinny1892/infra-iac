output "nlb_dns_name" {
  value = aws_lb.k3s_api_nlb.dns_name
}

output "cluster_endpoint" {
  value = "https://${aws_lb.k3s_api_nlb.dns_name}:6443"
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.k3s.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.k3s.url
}

output "aws_lb_controller_role_arn" {
  value = aws_iam_role.aws_lb_controller.arn
}

output "argocd_role_arn" {
  value = aws_iam_role.argocd.arn
}

output "vpc_id" {
  value = var.vpc_id
}
