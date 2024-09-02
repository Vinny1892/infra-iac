
module "internal_domain" {
  source = "../../../../modules/cloud_map"
  vpc_id = data.aws_vpc.vpc.id
  dns_name = "regulus.internal"
}