# Criar o serviço no Cloud Map


resource "aws_service_discovery_service" "service" {
  name          =  var.name
  dns_config {
    namespace_id = var.namespace_ip
    dns_records {
      type = "A"
      ttl  = 60
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_instance" "instance" {
  service_id  = aws_service_discovery_service.service.id
  instance_id = "ec2-${var.instance_id}"

  attributes = {
    "AWS_INSTANCE_IPV4" = var.ip
  }
}
