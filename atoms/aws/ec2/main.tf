resource "aws_iam_role" "ssm_role" {
  name = "${var.instance_name}-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_role_policy_attachment" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_instance_profile" {
  name = "${var.instance_name}-instance-profile"
  role = aws_iam_role.ssm_role.name
}
resource "aws_key_pair" "deployer" {
  key_name   = "personal_ssh-${var.instance_name}"
  public_key = file("~/.ssh/id_ed25519.pub")
}

resource "aws_instance" "ec2_instance" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.ssm_instance_profile.name

  tags = {
    Name = var.instance_name
  }

  # Habilita a integração com o SSM
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
}


