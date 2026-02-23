
locals {
  ubuntu_ami = "ami-0f3caa1cf4417e51b"
  ami_id = local.ubuntu_ami
  instance_name = "openclaw"
  instance_type = "t2.medium"
  domain_name = "openclaw.vinny.dev.br"
  type = "A"
}


 module "openclaw" {
  source            = "../../../../../../modules/ec2"
  instance_type     = local.instance_type
   ami_id = local.ami_id
  instance_name = local.instance_name
   subnet_id         = data.aws_subnets.selected.ids[0]
  security_group_ids = [data.aws_security_group.selected.id]
 }

# variable "cloudflare_zone_id" {
#   default = ""
# }

# variable "account_id" {
#   default = ""
# }

# module "tunnel" {
#    source =  "../../../../../../../cloudflare/modules/tunnel"
#    zone_id =  var.cloudflare_zone_id
#    domain = "teste2.vinny.dev.br"
#    tunnel_name = "tunnel_teste"
#    secret = "AQIDBAUGBwgBAgMEBQYHCAECAwQFBgcIAQIDBAUGBwg="
#    account_id = var.account_id

# } 

# module "dns_record" {
#  source = "../../../../../../../cloudflare/modules/domain"
#   # source = "git::git@github.com:Vinny1892/infra-iac.git//cloudflare/modules/domain?ref=master"
#   dns    = {
#     name =   local.domain_name
#     content = module.postgres.instance_public_ip
#     type = local.type
#   }
#   cloudflare_zone_id = var.cloudflare_zone_id
#   proxiable          = true
# }

