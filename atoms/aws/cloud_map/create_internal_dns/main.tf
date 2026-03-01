resource "aws_service_discovery_private_dns_namespace" "internal_dns" {
  name = var.dns_name
  vpc  = var.vpc_id
}

output "route53_zone_id" {
  value = aws_service_discovery_private_dns_namespace.internal_dns.hosted_zone
}

output "namespace_id" {
  description = "The ID of the service discovery namespace"
  value       = aws_service_discovery_private_dns_namespace.internal_dns.id
}

output "namespace_name" {
  description = "The name of the service discovery namespace"
  value       = aws_service_discovery_private_dns_namespace.internal_dns.name
}