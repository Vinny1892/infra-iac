output "instance_id" {
  value = module.instance.instance_id
}

output "public_ip" {
  value = module.instance.instance_public_ip
}

output "private_ip" {
  value = module.instance.instance_private_ip
}

output "secondary_vnic_ids" {
  value = module.instance.secondary_vnic_ids
}
