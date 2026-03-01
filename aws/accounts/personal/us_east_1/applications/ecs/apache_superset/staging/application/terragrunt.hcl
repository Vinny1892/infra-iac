include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "region" {
  path = find_in_parent_folders("_region.hcl")
}

dependency "ecs_cluster" {
  config_path = "../../../../../ecs_cluster"

  mock_outputs = {
    cluster_id = "arn:aws:ecs:us-east-1:000000000000:cluster/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "vpc" {
  config_path = "../../../../../network/vpc"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    subnet_public     = [{ id = "subnet-mock" }]
    security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "internal_domain" {
  config_path = "../../../../../internal_domain"

  mock_outputs = {
    namespace_id = "ns-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../../../molecules/aws/ecs/app"
}

inputs = {
  # Service
  service_name    = "apache-superset_staging"
  app_replicas    = 0
  cluster_id      = dependency.ecs_cluster.outputs.cluster_id
  vpc_id          = dependency.vpc.outputs.vpc_id
  security_groups = [dependency.vpc.outputs.security_group_id]
  subnets         = [for s in dependency.vpc.outputs.subnet_public : s.id]
  dns_app_name    = "apache-superset-staging"
  namespace_id    = dependency.internal_domain.outputs.namespace_id

  # Task
  task_name          = "apache-superset_staging"
  docker_image       = "vinny1892/superset-monolith:1.0.0"
  family             = "apache-superset_staging"
  secrets            = []
  resources          = { cpu = 256, memory = 512 }
  port_mapping       = [{ containerPort = 8088, hostPort = 8088 }]
  subnet_id          = dependency.vpc.outputs.subnet_public[0].id
  enable_efs         = false
  enable_cloud_watch = true
  cloud_watch_configuration = {
    logName = "/applications/apache_superset"
    region  = "us-east-1"
  }
  health_check_task = {
    healthCheck = {
      retries     = 3
      command     = ["CMD-SHELL", "curl -f http://localhost:8088/health || exit 0"]
      timeout     = 5
      interval    = 30
      startPeriod = null
    }
  }
  commands = ["/app/init_script/docker-bootstrap.sh", "app-gunicorn"]
  environment = [
    { name = "SUPERSET_LOAD_EXAMPLES", value = "true" },
    { name = "SUPERSET_CONFIG_PATH", value = "/app/superset_config.py" }
  ]
}
