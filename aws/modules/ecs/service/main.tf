
resource "aws_ecs_service" "service" {
  force_new_deployment              = true
  cluster = var.cluster_id
  desired_count                     = var.app_replicas
  enable_ecs_managed_tags           = true
  health_check_grace_period_seconds = 0
  name                              = var.service_name
  platform_version                  = "LATEST"
  propagate_tags                    = "NONE"
  task_definition                   = var.task_arn
  triggers                          = {}
  wait_for_steady_state             = false
  enable_execute_command            = true


  capacity_provider_strategy { # forces replacement
    base              = 0
    capacity_provider = "FARGATE"
    weight            = 1
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  network_configuration {
    assign_public_ip = true
    security_groups = var.security_groups
    subnets = var.subnets
  }

  dynamic "service_registries" {
    for_each = var.assign_lb_with_cloud_map == false ? [1] : []
    content {
        registry_arn   = aws_service_discovery_service.internal_dns_app.arn
    }
  }

  dynamic "load_balancer" {
    for_each = var.enable_lb ? [1] : []
    content {
        target_group_arn = var.lb_configuration.target_group_arn
        container_name   = var.lb_configuration.container_name
        container_port   = var.lb_configuration.container_port
      }
    }

  lifecycle {
    ignore_changes = [
      tags
    ]
  }
  }

