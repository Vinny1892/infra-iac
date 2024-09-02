locals {
  cloudwatch = {
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-create-group  = "true"
            awslogs-group         = aws_cloudwatch_log_group.log_group[0].name
            awslogs-region        =  var.cloud_watch_configuration.region
            awslogs-stream-prefix = "ecs"
          }
          secretOptions = []
      }
  }
  base = {
    cpu              = 0
    environment      = var.environment
    environmentFiles = []
    image            =  var.docker_image
    mountPoints = []
    essential   = true
    name        = var.task_name
    portMappings = var.port_mapping
    ulimits     = []
    volumesFrom = []
    secrets =  var.secrets
    linuxParameters: {
	  initProcessEnabled: true
    }
    enableExecuteCommand = true
  }
  application_without_health_check = merge(
    local.base,
      var.enable_cloud_watch ? local.cloudwatch : {}
  )
  application_with_health_check = merge(local.application_without_health_check, var.health_check_task)
  application_with_efs_configuration = merge(
    local.application_with_health_check,
      length(var.efs_configuration.mount_point) > 0 ? { mountPoint = var.efs_configuration.mount_point }: {}
  )
  application =  merge(
    local.application_with_efs_configuration,
      length(var.commands) > 0 ? { command = var.commands } : {}
  )
}

resource "aws_ecs_task_definition" "task" {
  container_definitions = jsonencode(
    [
      local.application
    ]
  )
  skip_destroy       = true
  cpu                = var.resources.cpu
  execution_role_arn =  aws_iam_role.task_execution_ecs.arn
  task_role_arn      =  aws_iam_role.task_execution_ecs.arn
  family             = var.family 
  memory             = var.resources.memory
  network_mode = "awsvpc"

  dynamic "volume" {
    for_each = var.enable_efs ? [1] : []
    content {
      name = "efs-${var.task_name}"
      efs_volume_configuration {
        file_system_id = aws_efs_file_system.efs[0].id
        root_directory = "/"
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = aws_efs_access_point.access_point[0].id
          iam = "ENABLED"
        }
      }
    }
  }

  requires_compatibilities = [
    "FARGATE",
  ]

  runtime_platform { # forces replacement
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

}

output "task_arn" {
  value = aws_ecs_task_definition.task.arn
}

output "debug" {
  value = local.application
}