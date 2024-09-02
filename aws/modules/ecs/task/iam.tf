resource "aws_iam_role_policy" "ecs_execute_command_policy" {
  name = "ecsExecuteCommandPolicy"
  role = aws_iam_role.task_execution_ecs.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}


resource "aws_iam_role" "task_execution_ecs" {
  name = "task_execution_ecs-${var.task_name}"


  assume_role_policy = jsonencode({
    Version   = "2008-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "efs_role_policy" {
  count      = var.enable_efs ? 1 : 0
  role       = aws_iam_role.task_execution_ecs.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess"
}

resource "aws_iam_role_policy_attachment" "policy_attachment" {
  role       = aws_iam_role.task_execution_ecs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_iam_role" "task_role" {
  name = "ecsTaskRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}
