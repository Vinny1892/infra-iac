variable "argocd_role_arn" {
  type = string
}

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
  type = string
}
