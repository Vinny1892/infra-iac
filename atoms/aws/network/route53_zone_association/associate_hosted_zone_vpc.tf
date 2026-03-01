terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      configuration_aliases = [
        aws.alternative
      ]
    }
  }
}

variable "vpc_id" {}
variable "aws_route53_zone_id" {}

resource "aws_route53_vpc_association_authorization" "authorization" {
  vpc_id  = var.vpc_id
  zone_id = var.aws_route53_zone_id
}

resource "aws_route53_zone_association" "zone_association" {
  provider = aws.alternative
  vpc_id   = aws_route53_vpc_association_authorization.authorization.vpc_id
  zone_id  = aws_route53_vpc_association_authorization.authorization.zone_id
}