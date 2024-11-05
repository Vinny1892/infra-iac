# Criar role para o EKS

data "aws_iam_policy_document" "worker_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com", "eks.amazonaws.com"]
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "test_role" {
  name               = "${var.cluster_name}-test_role"
  assume_role_policy = data.aws_iam_policy_document.worker_assume_role_policy.json
}

resource "aws_iam_policy" "parameter_store_policy" {
  name        = "ParameterStoreReadPolicy"
  description = "Permissões de leitura para o AWS Systems Manager Parameter Store"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ],
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "parameter_store_role_policy" {
  role       = aws_iam_role.test_role.name
  policy_arn = aws_iam_policy.parameter_store_policy.arn
}

resource "aws_iam_role" "eks_cluster_role" {
  name               = "${var.cluster_name}-eks-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role_policy.json
}

data "aws_iam_policy_document" "eks_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.id
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks_cluster_role.id
}

# Criar o cluster EKS
resource "aws_eks_cluster" "eks_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn


  vpc_config {
    subnet_ids = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  version = var.cluster_version
}

# Criar role para os workers (EC2)
resource "aws_iam_role" "eks_worker_role" {
  name               = "${var.cluster_name}-worker-role"
  assume_role_policy = data.aws_iam_policy_document.worker_assume_role_policy.json
}


resource "aws_iam_role_policy_attachment" "eks_worker_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_worker_role.id
}

resource "aws_iam_role_policy_attachment" "example-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       =  aws_iam_role.eks_worker_role.id
}

resource "aws_iam_role_policy_attachment" "eks_worker_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_worker_role.id
}

resource "aws_iam_instance_profile" "eks_worker_profile" {
  name = "${var.cluster_name}-worker-profile"
  role = aws_iam_role.eks_worker_role.name
}

resource "aws_eks_node_group" "node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.eks_worker_role.arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }
    depends_on = [
    aws_iam_role_policy_attachment.eks_worker_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.example-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.eks_worker_AmazonEC2ContainerRegistryReadOnly,
  ]

}


resource "aws_eks_addon" "addon1"{
  cluster_name = aws_eks_cluster.eks_cluster.name
  addon_name = "vpc-cni"
  addon_version = "v1.18.3-eksbuild.3"
}
resource "aws_eks_addon" "addon3"{
  cluster_name = aws_eks_cluster.eks_cluster.name
  addon_name = "eks-pod-identity-agent"
  addon_version = "v1.3.2-eksbuild.2"
  service_account_role_arn = aws_iam_role.test_role.arn
}
# resource "aws_eks_addon" "addon2"{
#   cluster_name = aws_eks_cluster.eks_cluster.name
#   addon_name = "EBS-CSI"
#   addon_version = "v1.34.0-eksbuild.1"
# }

data "tls_certificate" "this" {
  url = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}


resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.this.certificates[0].sha1_fingerprint]
  url = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}