variable "region" {
  default = "us-east-1"
}

variable "availability_zone" {
  default = "us-east-1a"
}

variable "masters_count" {
  default = 2
}

variable "workers_count" {
  default = 2
}

variable "token" {}

locals {
  cluster_dns_name = aws_lb.nlb.dns_name
}


data "aws_security_group" "selected" {
  filter {
    name   = "tag:Name"
    values = ["securitygroupzinho"]
  }
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
  filter {
    name   = "tag:type_subnet"
    values = ["public"]
  }

  filter {
      name   = "availability-zone"
      values = [var.availability_zone ]
    }
}
data "aws_subnets" "db_subnet" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
  filter {
    name   = "tag:type_subnet"
    values = ["public"]
  }

}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["MainVPC"]
  }
}




resource "aws_security_group" "k3s_sg" {
  vpc_id = data.aws_vpc.vpc.id

  ingress {
    from_port = 6443
    to_port   = 6443
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_iam_role" "ssm_role" {
  name               = "k3s-masters-lt-ssm-role"
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
  name = "k3s-masters-lt-instance-profile"
  role = aws_iam_role.ssm_role.name
}

resource "aws_launch_template" "masters_lt" {
  name          = "k3s-masters-lt"
  image_id      = "ami-01816d07b1128cd2d"
  instance_type = "t2.medium"
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]
  iam_instance_profile {
    name = aws_iam_instance_profile.ssm_instance_profile.name
  }
#   network_interfaces {
#     associate_public_ip_address = true
#     security_groups = [aws_security_group.k3s_sg.id]
#     subnet_id =  data.aws_subnets.selected.ids[0]
#   }
# postgres://${username}:${password}@${hostname}:${port}/${database_name}
  user_data = base64encode(templatefile("./scripts/init-master.tfpl",
    {
      token = var.token
      username = aws_db_instance.k3s_rds.username
      password = aws_db_instance.k3s_rds.password
      hostname = aws_db_instance.k3s_rds.address
      port = aws_db_instance.k3s_rds.port
      database_name = aws_db_instance.k3s_rds.db_name
      dns_name = local.cluster_dns_name
    }))
}

resource "aws_autoscaling_group" "masters_asg" {
  name = "seila"
  launch_template {
    id      = aws_launch_template.masters_lt.id
    version = "$Latest"
  }
  min_size             = var.masters_count
  max_size             = var.masters_count
  desired_capacity     = var.masters_count
  vpc_zone_identifier  = data.aws_subnets.selected.ids
}

# resource "aws_launch_template" "workers_lt" {
#   name          = "k3s-workers-lt"
#   image_id      = "ami-0c55b159cbfafe1f0"
#   instance_type = "t2.medium"
#   security_group_ids = [aws_security_group.k3s_sg.id]
#
#   user_data = base64encode(<<-EOF
#               #!/bin/bash
#               curl -sfL https://get.k3s.io | K3S_URL=https://${var.cluster_dns_name}:6443 K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token) sh -
#               EOF
#   )
# }
#
# resource "aws_autoscaling_group" "workers_asg" {
#   launch_template {
#     id      = aws_launch_template.workers_lt.id
#     version = "$Latest"
#   }
#   min_size             = var.workers_count
#   max_size             = var.workers_count
#   desired_capacity     = var.workers_count
#   vpc_zone_identifier  = [aws_subnet.k3s_subnets[1].id]
#   tags = [{
#     key                 = "Name"
#     value               = "k3s-worker"
#     propagate_at_launch = true
#   }]
# }

resource "aws_lb" "nlb" {
  name               = "k3s-nlb"
  internal           = false
  load_balancer_type = "network"
  subnet_mapping {
    subnet_id = data.aws_subnets.selected.ids[0]
  }
}

resource "aws_lb_target_group" "masters_tg" {
  name     = "k3s-masters-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = data.aws_vpc.vpc.id
}

resource "aws_autoscaling_attachment" "masters_attachment" {
  autoscaling_group_name = aws_autoscaling_group.masters_asg.name
  lb_target_group_arn    = aws_lb_target_group.masters_tg.arn
}

resource "aws_lb_listener" "nlb_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 6443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.masters_tg.arn
  }
}

resource "aws_security_group" "database_sg" {
  vpc_id = data.aws_vpc.vpc.id

  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "k3s_rds" {
  identifier        = "k3s-db"
  allocated_storage = 20
  engine            = "postgres"
  instance_class    = "db.t3.micro"
  username          = "teste"
  password          = "password"
  db_subnet_group_name = aws_db_subnet_group.k3s_subnet_group.name
  skip_final_snapshot = true
  db_name              = "k3s"
  vpc_security_group_ids = [aws_security_group.database_sg.id]
}

resource "aws_db_subnet_group" "k3s_subnet_group" {
  name       = "k3s-subnet-group"
  subnet_ids =  data.aws_subnets.db_subnet.ids
}
