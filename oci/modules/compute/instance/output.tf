output "instance_id" {
  description = "OCID da instância"
  value       = oci_core_instance.instance.id
}

output "instance_public_ip" {
  description = "IP público da instância"
  value       = oci_core_instance.instance.public_ip
}

output "instance_private_ip" {
  description = "IP privado da instância"
  value       = oci_core_instance.instance.private_ip
}
