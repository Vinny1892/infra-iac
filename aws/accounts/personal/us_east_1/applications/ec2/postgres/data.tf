# data "aws_security_group" "selected" {
#   filter {
#     name   = "tag:Name"
#     values = ["securitygroupzinho"]
#   }
# }

# data "aws_subnets" "selected" {
#   filter {
#     name   = "vpc-id"
#     values = [data.aws_vpc.vpc.id]
#   }
#   filter {
#     name   = "tag:type_subnet"
#     values = ["public"]
#   }
# }

# data "aws_vpc" "vpc" {
#   filter {
#     name   = "tag:Name"
#     values = ["MainVPC"]
#   }
# }

# data "aws_service_discovery_dns_namespace" "internal_dns" {
#   name = "regulus.internal"
#   type = "DNS_PRIVATE"
# }
