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

output "primary_subnet_id" {
  description = "Subnet primária efetiva usada pela instância"
  value       = local.effective_primary_subnet_id
}

output "secondary_vnic_ids" {
  description = "IDs das VNICs secundárias anexadas"
  value       = [for attachment in oci_core_vnic_attachment.secondary : attachment.vnic_id]
}
