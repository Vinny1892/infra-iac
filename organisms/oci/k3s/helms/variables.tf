variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = ""
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
