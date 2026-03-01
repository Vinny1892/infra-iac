variable "vpc_id" {}


resource "aws_security_group" "example" {
  # ... other configuration ...
  description = "seila"
  vpc_id      = var.vpc_id


  egress {
    description = "egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ingress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "securitygroupzinho"
  }
}