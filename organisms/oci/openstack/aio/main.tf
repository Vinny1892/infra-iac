module "instance" {
  source = "../../../../atoms/oci/compute/instance"

  compartment_id                = var.compartment_id
  availability_domain           = var.availability_domain
  subnet_id                     = var.primary_subnet_id
  primary_subnet_id             = var.primary_subnet_id
  secondary_vnic_subnet_ids     = var.secondary_vnic_subnet_ids
  instance_name                 = var.instance_name
  ssh_port                      = var.ssh_port
  shape                         = var.shape
  ocpus                         = var.ocpus
  memory_in_gbs                 = var.memory_in_gbs
  image_id                      = var.image_id
  assign_public_ip              = var.assign_public_ip
  ssh_public_key_path           = var.ssh_public_key_path
  marketplace_listing_id        = var.marketplace_listing_id
  marketplace_listing_version   = var.marketplace_listing_version
  marketplace_eula_link         = var.marketplace_eula_link
  marketplace_oracle_terms_link = var.marketplace_oracle_terms_link
  marketplace_signature         = var.marketplace_signature
  marketplace_time_retrieved    = var.marketplace_time_retrieved
  user_data_base64 = base64encode(templatefile("${path.module}/templates/cloud-init.sh.tpl", {
    hostname          = var.instance_name
    ssh_port          = var.ssh_port
    timezone          = var.timezone
    admin_user        = var.admin_user
    provider_nic_name = var.provider_nic_name
  }))
}
