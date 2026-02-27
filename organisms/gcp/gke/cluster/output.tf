output "endpoint" {
  value = module.cluster_gke.endpoint
}

output "ca_certificate" {
  value = module.cluster_gke.ca_certificate
}

output "token" {
  value     = module.cluster_gke.token
  sensitive = true
}
