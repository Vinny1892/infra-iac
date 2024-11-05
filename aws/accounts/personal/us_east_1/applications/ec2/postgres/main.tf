
locals {
 # ami_id = "ami-0182f373e66f89c85"
   ami_id = "ami-0281b255889b71ea7"
  instance_name = "postgres"
  instance_type = "t2.micro"
  domain_name = "database.vinny.dev.br"
  type = "A"
}


# module "postgres" {
#   source            = "../../../../../../modules/ec2"
#   instance_type     = local.instance_type
#   ami_id = local.ami_id
#   instance_name = local.instance_name
#   subnet_id         = data.aws_subnets.selected.ids[0]
#   security_group_ids = [data.aws_security_group.selected.id]
# }

variable "cloudflare_zone_id" {
  default = ""
}

variable "account_id" {
  default = ""
}

module "tunnel" {
   source =  "../../../../../../../cloudflare/modules/tunnel"
   zone_id =  var.cloudflare_zone_id
   domain = "teste2.vinny.dev.br"
   tunnel_name = "tunnel_teste"
   secret = "AQIDBAUGBwgBAgMEBQYHCAECAwQFBgcIAQIDBAUGBwg="
   account_id = var.account_id

} 

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

# module "internal_dns" {
#   source = "../../../../../../modules/cloud_map/internal_domain"
#   instance_id = module.postgres.instance_id
#   name = local.instance_name
#   ip = module.postgres.instance_private_ip
#   namespace_ip = data.aws_service_discovery_dns_namespace.internal_dns.id
# }
