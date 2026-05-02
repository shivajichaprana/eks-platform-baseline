###############################################################################
# Karpenter module — input variables.
#
# Inputs are intentionally narrow: this module wires Karpenter to an existing
# EKS cluster (provided by the `eks` module) and produces the IRSA service
# role, the EC2 instance profile that nodes assume, the SQS interruption
# queue + EventBridge rules, and the Helm release of the Karpenter
# controller. Callers that need a different controller version, namespace,
# or replica count override the corresponding variables.
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster Karpenter will manage. Must match the name returned by the eks module."
  type        = string

  validation {
    condition     = length(var.cluster_name) > 0 && length(var.cluster_name) <= 100
    error_message = "cluster_name must be between 1 and 100 characters."
  }
}

variable "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster (https://...). Used by the Karpenter controller to talk to the API server."
  type        = string

  validation {
    condition     = can(regex("^https://", var.cluster_endpoint))
    error_message = "cluster_endpoint must start with https://."
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider associated with the cluster. Used to scope the IRSA trust policy."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC provider URL with the leading https:// stripped (e.g. oidc.eks.us-east-1.amazonaws.com/id/ABCD1234). Used to build the IRSA condition key."
  type        = string
}

variable "node_iam_role_name" {
  description = "Name of the worker-node IAM role created by the eks module. Karpenter will reuse this role for nodes it provisions, so we attach an aws-auth mapping in the cluster (handled by the eks module) and create an instance profile from it here."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace into which the Karpenter controller is deployed."
  type        = string
  default     = "karpenter"
}

variable "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount used by Karpenter pods. The IRSA role is bound to this SA."
  type        = string
  default     = "karpenter"
}

variable "chart_version" {
  description = "OCI Helm chart version for Karpenter (oci://public.ecr.aws/karpenter/karpenter). Pin to a specific version so `terraform plan` is reproducible."
  type        = string
  default     = "1.0.6"
}

variable "controller_replicas" {
  description = "Number of Karpenter controller replicas. Two replicas with leader election is the recommended HA configuration."
  type        = number
  default     = 2

  validation {
    condition     = var.controller_replicas >= 1 && var.controller_replicas <= 5
    error_message = "controller_replicas must be between 1 and 5."
  }
}

variable "controller_resources" {
  description = "CPU/memory requests and limits for the Karpenter controller pod."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "200m", memory = "512Mi" }
    limits   = { cpu = "1",    memory = "1Gi" }
  }
}

variable "log_level" {
  description = "Log level for the Karpenter controller (debug, info, warn, error)."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of debug, info, warn, error."
  }
}

variable "create_service_account" {
  description = "Whether the Helm chart should create the ServiceAccount. Set to true unless the SA is managed externally (e.g. by GitOps)."
  type        = bool
  default     = true
}

variable "node_termination_handler_enabled" {
  description = "Whether to wire the SQS interruption queue + EventBridge rules. Required for graceful spot-interruption handling. Disable only for cost-sensitive non-prod where 2-minute spot interruptions are acceptable."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all AWS resources created by this module."
  type        = map(string)
  default     = {}
}
