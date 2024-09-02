
module "staging_loki" {
  source = "../../../../../../../modules/ecs/service"
  app_replicas = 1
  cluster_id = data.aws_ecs_cluster.cluster.id
  enable_lb = false
  assign_lb_with_cloud_map = false
  internal_dns = {
    dns_app_name = "loki-staging"
    dns_id = data.aws_service_discovery_dns_namespace.internal_dns.id
  }
  vpc_id = data.aws_vpc.vpc.id
  service_name = "loki-staging"
  task_arn = module.task.task_arn
  security_groups = ["sg-0307995ed6e09f739"]
  subnets = ["subnet-06dc6a37ecd9bd3c4", "subnet-02615695f8c4c58ce"]
  depends_on = [module.task]
}


module task {
  source = "../../../../../../../modules/ecs/task"
  docker_image = "207498280574.dkr.ecr.us-east-1.amazonaws.com/platform-watch-stack/loki"
  family = "loki-staging"
  secrets = []
  resources = {
    cpu = 256
    memory = 512
  }
  port_mapping = [{
    containerPort: 3100
    hostPort: 3100
  }]
  task_name = "loki-staging"
  enable_efs = true
  enable_cloud_watch = true
  cloud_watch_configuration = {
    logName = "/org/principia/loki-staging"
    region = "us-east-1"
  }
  subnet_id = data.aws_subnet.selected.id
  health_check_task = {
    "healthCheck": {
      "retries": 3,
      "command": [
        "CMD-SHELL",
        "curl -f http://localhost:3100/ready || exit 0"
      ],
      "timeout": 5,
      "interval": 30,
      "startPeriod": null
    },
  }
  efs_configuration = {
    transition_to_ia = "AFTER_30_DAYS"
    root_directory = "/loki"
    mount_point = [{
      "sourceVolume": "efs-loki",
      "containerPath": "/loki",
      "readOnly": false
    }]
  }

}
