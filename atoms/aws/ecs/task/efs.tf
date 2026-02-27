
resource "aws_efs_file_system" "efs" {
  count = var.enable_efs ? 1 : 0
  encrypted = true
  lifecycle_policy {
    transition_to_ia = var.efs_configuration.transition_to_ia
  }
  tags = {
    Name = "ECS-EFS-${var.task_name}"
  }

}

resource "aws_efs_mount_target" "mount" {
  count = var.enable_efs ? 1 : 0
  file_system_id = aws_efs_file_system.efs[0].id
  subnet_id      = var.subnet_id
}

resource "aws_efs_access_point" "access_point" {
  count = var.enable_efs ? 1 : 0
  file_system_id = aws_efs_file_system.efs[0].id
  posix_user {
    uid = 1001
    gid = 1001
  }
  root_directory {
    path = var.efs_configuration.root_directory
    creation_info {
      owner_uid = 1001
      owner_gid = 1001
      permissions = 750
    }
  }
  tags = {
    Name = var.task_name
  }
}
