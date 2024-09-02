
locals {
  app_name = "apache-superset_staging"
}

module "apache_superset" {
  source = "../../../../../../../../modules/ecs/service"
  app_replicas = 0
  cluster_id = data.aws_ecs_cluster.cluster.id
  enable_lb = false
  assign_lb_with_cloud_map = false
  internal_dns = {
    dns_app_name = "apache-superset-staging"
    dns_id = data.aws_service_discovery_dns_namespace.internal_dns.id
  }
  vpc_id = data.aws_vpc.vpc.id
  service_name = local.app_name
  task_arn = module.task.task_arn
  security_groups = [data.aws_security_group.sg.id]
  subnets = data.aws_subnets.selected.ids
  depends_on = [module.task]
}


module task {
  source = "../../../../../../../../modules/ecs/task"
  docker_image = "vinny1892/superset-monolith:1.0.0"
  family = local.app_name
  secrets = []
  resources = {
    cpu = 256
    memory = 512
  }
  port_mapping = [{
    containerPort: 8088
    hostPort: 8088
  }]
  task_name = local.app_name
  enable_efs = false
  enable_cloud_watch = true
  cloud_watch_configuration = {
    logName = "/applications/apache_superset"
    region = "us-east-1"
  }
  subnet_id = data.aws_subnets.selected.id
  health_check_task = {
    "healthCheck": {
      "retries": 3,
      "command": [
        "CMD-SHELL",
        "curl -f http://localhost:8088/health || exit 0"
      ],
      "timeout": 5,
      "interval": 30,
      "startPeriod": null
    },
  }
  commands =  [
    "/app/init_script/docker-bootstrap.sh",
    "app-gunicorn"
  ]
  environment = [
    {name = "SUPERSET_LOAD_EXAMPLES", value = "true"},
    {name = "SUPERSET_CONFIG_PATH", value = "/app/superset_config.py"}
  ]
}