variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "vm_public_ip" {
  type        = string
  description = "IP público da VM OCI para configurar o MetalLB"
}

variable "vm_instance_id" {
  type        = string
  description = "OCID da instância. Usado como trigger do metallb_config: identifica o cluster e muda a cada recriação da VM, o que vm_public_ip deixou de fazer quando o IP passou a ser reservado."
}

variable "github_owner" {
  type = string
}

variable "github_app_id" {
  type = string
}

variable "github_app_installation_id" {
  type = string
}

variable "github_repo_name" {
  type    = string
  default = "infra-iac"
}

variable "github_app_private_key" {
  type      = string
  sensitive = true
}

variable "github_oauth_client_id" {
  type = string
}

variable "github_oauth_client_secret" {
  type      = string
  sensitive = true
}

variable "onepassword_service_account_token" {
  description = "Token do Service Account do 1Password usado pelo External Secrets Operator (op://IAM/Service Account Auth Token: K3s/credencial)"
  type        = string
  sensitive   = true
}
