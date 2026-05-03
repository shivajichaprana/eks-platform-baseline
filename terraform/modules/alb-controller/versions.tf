###############################################################################
# AWS Load Balancer Controller — provider version constraints.
#
# We pin the same major versions as the root module so a single `terraform
# init` from any environment composes one provider tree with no version
# conflicts.
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
