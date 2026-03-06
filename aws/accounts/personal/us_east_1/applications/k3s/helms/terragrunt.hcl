include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../organisms/aws/k3s/helms"
}

dependency "k3s_cluster" {
  config_path = "../cluster"

  mock_outputs = {
    argocd_role_arn = "arn:aws:iam::123456789012:role/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  argocd_role_arn            = dependency.k3s_cluster.outputs.argocd_role_arn
  github_owner               = get_env("GITHUB_OWNER", "")
  github_app_id              = get_env("GITHUB_APP_ID", "")
  github_app_installation_id = get_env("GITHUB_APP_INSTALL_ID", "")
  github_repo_name           = get_env("GITHUB_REPO_NAME", "infra-iac")
}
