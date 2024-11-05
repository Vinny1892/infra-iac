provider "helm" {
 kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster_auth.token
  }
}

provider "aws" {
  region = "us-east-1"
  profile = "sandim-account"
  default_tags {
    tags = {
      managed_by = "terraform"
      environment = "testing"
      account = "personal"
    }
  }
}