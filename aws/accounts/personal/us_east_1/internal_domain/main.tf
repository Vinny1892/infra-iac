
module "internal_domain" {
  source = "../../../../modules/cloud_map/create_internal_dns"
  vpc_id = data.aws_vpc.vpc.id
  dns_name = "regulus.internal"
}