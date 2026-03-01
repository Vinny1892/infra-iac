data "aws_ecs_cluster" "cluster" {
  count        = var.cluster_id == null ? 1 : 0
  cluster_name = var.cluster_name
}

data "aws_service_discovery_dns_namespace" "ns" {
  count = var.namespace_id == null ? 1 : 0
  name  = var.namespace_name
  type  = "DNS_PRIVATE"
}

locals {
  cluster_id   = var.cluster_id != null ? var.cluster_id : data.aws_ecs_cluster.cluster[0].id
  namespace_id = var.namespace_id != null ? var.namespace_id : data.aws_service_discovery_dns_namespace.ns[0].id
}

module "task" {
  source = "../../../atoms/aws/ecs/task"

  task_name                 = var.task_name
  docker_image              = var.docker_image
  family                    = var.family
  secrets                   = var.secrets
  resources                 = var.resources
  port_mapping              = var.port_mapping
  enable_efs                = var.enable_efs
  enable_cloud_watch        = var.enable_cloud_watch
  cloud_watch_configuration = var.cloud_watch_configuration
  subnet_id                 = var.subnet_id
  health_check_task         = var.health_check_task
  efs_configuration         = var.efs_configuration
  commands                  = var.commands
  environment               = var.environment
}

module "service" {
  source = "../../../atoms/aws/ecs/service"

  app_replicas             = var.app_replicas
  cluster_id               = local.cluster_id
  enable_lb                = var.enable_lb
  assign_lb_with_cloud_map = var.assign_lb_with_cloud_map
  internal_dns = {
    dns_app_name = var.dns_app_name
    dns_id       = local.namespace_id
  }
  vpc_id           = var.vpc_id
  service_name     = var.service_name
  task_arn         = module.task.task_arn
  security_groups  = var.security_groups
  subnets          = var.subnets
  lb_configuration = var.lb_configuration

  depends_on = [module.task]
}
