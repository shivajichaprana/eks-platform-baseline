###############################################################################
# Dev environment root module
#
# This is a thin composition that wires the VPC and EKS modules together with
# values that suit a single-engineer development cluster. Production
# environments should clone this module and override variables.
###############################################################################

terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "eks-platform-baseline"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = {
    Project     = "eks-platform-baseline"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name             = "${var.cluster_name}-vpc"
  cidr             = var.vpc_cidr
  azs              = var.availability_zones
  private_subnets  = var.private_subnet_cidrs
  public_subnets   = var.public_subnet_cidrs
  enable_nat       = true
  single_nat_gw    = true # cost-optimised for dev; set false in prod
  cluster_name     = var.cluster_name
  enable_endpoints = true
  tags             = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name              = var.cluster_name
  cluster_version           = var.cluster_version
  subnet_ids                = module.vpc.private_subnet_ids
  vpc_id                    = module.vpc.vpc_id
  endpoint_public_access    = true
  endpoint_public_cidrs     = var.endpoint_public_cidrs
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager"]
  log_retention_days        = 30

  system_node_group = {
    instance_types = ["t3.medium"]
    desired_size   = 2
    min_size       = 2
    max_size       = 4
    disk_size_gib  = 50
    labels         = { "workload" = "system" }
    taints = [{
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }

  tags = local.common_tags
}
