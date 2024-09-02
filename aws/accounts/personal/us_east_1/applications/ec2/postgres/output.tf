output "instance_id" {
  description = "The ID of the EC2 instance"
  value       = module.postgres.instance_id
}

output "instance_public_ip" {
  description = "The public IP of the EC2 instance"
  value       = module.postgres.instance_public_ip
}

output "instance_private_ip" {
  description = "The private IP of the EC2 instance"
  value       = module.postgres.instance_private_ip
}
