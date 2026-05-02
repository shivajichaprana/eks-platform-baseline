###############################################################################
# Karpenter module — provider version constraints.
#
# We pin provider major versions to match the root module so that running
# `terraform init` from any environment composes a single provider tree.
###############################################################################

terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}
