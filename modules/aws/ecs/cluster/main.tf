# ECS

resource "aws_ecs_cluster" "cluster" {

  name = var.cluster_name

  # configuration {
  #   execute_command_configuration {
  #     logging = "DEFAULT"
  #   }
  # }

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

