###############################################################################
# VPC module — input variables
###############################################################################

variable "name" {
  description = "Name prefix applied to VPC and child resources"
  type        = string

  validation {
    condition     = length(var.name) > 0 && length(var.name) <= 64
    error_message = "name must be 1-64 characters."
  }
}

variable "cidr" {
  description = "CIDR block for the VPC. Must be a /16 - /28."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr))
    error_message = "cidr must be a valid CIDR block (e.g. 10.40.0.0/16)."
  }
}

variable "azs" {
  description = "Availability zones the subnets will be created in. Length must equal both private_subnets and public_subnets."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Need at least 2 AZs."
  }
}

variable "private_subnets" {
  description = "CIDR blocks for private subnets — used by EKS nodes and pods. One per AZ."
  type        = list(string)

  validation {
    condition     = length(var.private_subnets) >= 2
    error_message = "Need at least 2 private subnets."
  }
}

variable "public_subnets" {
  description = "CIDR blocks for public subnets — used by NAT GWs and load balancers. One per AZ."
  type        = list(string)

  validation {
    condition     = length(var.public_subnets) >= 2
    error_message = "Need at least 2 public subnets."
  }
}

variable "enable_nat" {
  description = "Whether to provision NAT Gateways for private subnet egress."
  type        = bool
  default     = true
}

variable "single_nat_gw" {
  description = "If true, create one NAT Gateway shared by all private subnets (cost-optimised). If false, one per AZ (HA)."
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "Name of the EKS cluster these subnets belong to. Used to apply kubernetes.io/cluster/<name>=shared tags so the AWS Load Balancer Controller can discover subnets."
  type        = string
}

variable "enable_endpoints" {
  description = "Provision baseline VPC endpoints (S3 gateway, ECR API/DKR interface, STS interface)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all VPC resources."
  type        = map(string)
  default     = {}
}
