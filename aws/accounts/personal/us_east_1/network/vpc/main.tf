module "vpc" {
  source                     = "../../../../../modules/network/vpc"
  vpc_cidr_block             = "10.10.0.0/16"
  public_subnet_cidr_blocks  = ["10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidr_blocks = ["10.10.3.0/24", "10.10.4.0/24"]
  availability_zone = ["us-east-1a", "us-east-1b"]
  region                     = "us-east-1"
}

module "security_group" {
  source = "../../../../../modules/network/security_group"
  vpc_id = module.vpc.vpc_id
}
