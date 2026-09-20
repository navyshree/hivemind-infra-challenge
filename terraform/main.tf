provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  # Local Zones and Wavelength Zones do not run EKS node groups.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name = var.project_name

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.additional_tags,
  )

  # Carve /20s out of the VPC CIDR: public subnets from the low end, private
  # from an offset so the two ranges stay visually distinct in the console and
  # leave room to widen either side later.
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = local.name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # Nodes live in private subnets and reach the internet through NAT; only the
  # load balancers are public.
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # Required for EKS: nodes resolve the cluster endpoint and each other by DNS.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs. Without them there is no record of who talked to what, so a
  # NetworkPolicy can be verified as configured but never as effective, and an
  # incident has no network evidence to reconstruct from.
  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_cloudwatch_log_group_retention_in_days = 30
  # REJECT only: accepted traffic is high-volume and low-signal here, while
  # rejects are what show a policy biting or something probing.
  flow_log_traffic_type = "REJECT"

  # Subnet discovery tags for the AWS Load Balancer Controller. Without these
  # the controller cannot decide where to place an ALB and ingress silently
  # never provisions.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}
