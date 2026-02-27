module "vpc" {
  source = "../../../atoms/aws/network/vpc"

  vpc_cidr_block             = var.vpc_cidr_block
  public_subnet_cidr_blocks  = var.public_subnet_cidr_blocks
  private_subnet_cidr_blocks = var.private_subnet_cidr_blocks
  availability_zone          = var.availability_zone
  region                     = var.region
}

module "security_group" {
  source = "../../../atoms/aws/network/security_group"
  vpc_id = module.vpc.vpc_id
}
