
locals {
  ami_id = "ami-0281b255889b71ea7"
  instance_name = "postgres"
  instance_type = "t2.micro"
}


module "postgres" {
  source            = "../../../../../../modules/ec2"
  instance_type     = local.instance_type
  ami_id = local.ami_id
  instance_name = local.instance_name
  subnet_id         = data.aws_subnets.selected.ids[0]
  security_group_ids = [data.aws_security_group.selected.id]
}

variable "cloudflare_zone_id" {
  default = ""
}
module "dns_record" {
  source = "../../../../../../../cloudflare/modules/domain"
  dns    = ""
  cloudflare_zone_id = var.cloudflare_zone_id
}
