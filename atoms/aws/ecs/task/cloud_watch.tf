resource "aws_cloudwatch_log_group" "log_group" {
  count = var.enable_cloud_watch ? 1 : 0
  name  = var.cloud_watch_configuration.logName
}
