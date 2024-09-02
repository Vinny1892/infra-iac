resource "aws_service_discovery_service" "internal_dns_app" {
  name = var.internal_dns.dns_app_name

  dns_config {
    namespace_id = var.internal_dns.dns_id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}