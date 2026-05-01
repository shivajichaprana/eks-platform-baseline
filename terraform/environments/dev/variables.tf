variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag (team or individual)"
  type        = string
  default     = "platform-eng"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "dev-eks"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}$", var.cluster_name))
    error_message = "cluster_name must be 2-39 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane"
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.40.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets across (must be >= 3 for production)"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Need at least two AZs for HA."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.40.0.0/19", "10.40.32.0/19", "10.40.64.0/19"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.40.96.0/22", "10.40.100.0/22", "10.40.104.0/22"]
}

variable "endpoint_public_cidrs" {
  description = "Allow-list for the EKS public endpoint. Default is open; lock down in prod."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
