resource "aws_service_discovery_private_dns_namespace" "internal_dns" {
  name = var.dns_name
  vpc = var.vpc_id
}

output "route53_zone_id" {
  value = aws_service_discovery_private_dns_namespace.internal_dns.hosted_zone
}