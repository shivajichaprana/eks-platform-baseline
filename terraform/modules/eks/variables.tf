###############################################################################
# EKS module — input variables
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}$", var.cluster_name))
    error_message = "cluster_name must be 2-39 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane (e.g. \"1.30\")."
  type        = string
  default     = "1.30"

  validation {
    condition     = can(regex("^1\\.(2[5-9]|3[0-9])$", var.cluster_version))
    error_message = "cluster_version must be a supported EKS minor version (1.25 - 1.39)."
  }
}

variable "vpc_id" {
  description = "VPC ID the cluster's ENIs and node groups will live in"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets where the EKS control-plane ENIs and managed node group(s) are placed. These should be PRIVATE subnets across multiple AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Need subnets in at least two AZs."
  }
}

variable "endpoint_private_access" {
  description = "Whether the EKS API server is reachable from inside the VPC."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Whether the EKS API server is reachable from the internet."
  type        = bool
  default     = true
}

variable "endpoint_public_cidrs" {
  description = "CIDRs permitted to reach the public endpoint when endpoint_public_access = true. Ignored otherwise."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  description = "Control-plane log types to ship to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager"]

  validation {
    condition = alltrue([
      for t in var.enabled_cluster_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "enabled_cluster_log_types entries must be one of api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the /aws/eks/<cluster>/cluster log group."
  type        = number
  default     = 30
}

variable "system_node_group" {
  description = <<EOT
Configuration for the system managed node group. This group runs CoreDNS, kube-proxy,
metrics-server, the addon controllers, and other CriticalAddonsOnly workloads. Application
workloads should land on Karpenter-provisioned nodes (Day 38).
EOT
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size_gib  = number
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
    capacity_type = optional(string, "ON_DEMAND")
  })

  validation {
    condition     = var.system_node_group.min_size <= var.system_node_group.desired_size && var.system_node_group.desired_size <= var.system_node_group.max_size
    error_message = "system_node_group sizes must satisfy min_size <= desired_size <= max_size."
  }

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.system_node_group.capacity_type)
    error_message = "system_node_group.capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "tags" {
  description = "Tags applied to all EKS-related resources."
  type        = map(string)
  default     = {}
}
