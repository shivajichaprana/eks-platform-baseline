###############################################################################
# AWS Load Balancer Controller — input variables.
#
# This module wires the AWS Load Balancer Controller (LBC) to an existing
# EKS cluster (provided by the `eks` module). It produces:
#
#   * the IRSA role + policy the controller pod assumes,
#   * the Helm release of the controller in `kube-system`.
#
# Most callers only need to set `cluster_name`, `vpc_id`, and the IRSA
# inputs (oidc_provider_arn / oidc_provider_host) from the eks module's
# outputs. Everything else has sane production defaults.
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster the controller will manage. The controller embeds this value in ALB tags and uses it for service discovery."
  type        = string

  validation {
    condition     = length(var.cluster_name) > 0 && length(var.cluster_name) <= 100
    error_message = "cluster_name must be between 1 and 100 characters."
  }
}

variable "vpc_id" {
  description = "VPC ID where ALBs will be provisioned. Passed straight through to the controller as --aws-vpc-id."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-xxxxxxxx."
  }
}

variable "region" {
  description = "AWS region where the cluster runs. Used by the controller for EC2 / ELB API calls."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA. Output `oidc_provider_arn` of the eks module."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC issuer host with the leading https:// stripped (e.g. oidc.eks.us-east-1.amazonaws.com/id/ABCD1234). Used as the IAM trust-policy condition variable."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the controller will run. kube-system is conventional and lets it benefit from the system priority class without extra annotations."
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount used by controller pods. The IRSA role's trust policy is scoped to this SA."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "chart_repository" {
  description = "Helm repository hosting the controller chart. The official chart is published at https://aws.github.io/eks-charts."
  type        = string
  default     = "https://aws.github.io/eks-charts"
}

variable "chart_version" {
  description = "Helm chart version. Pin to a specific release so `terraform plan` is reproducible."
  type        = string
  default     = "1.8.1"
}

variable "controller_image_tag" {
  description = "Optional override for the controller image tag. Leave empty to use the chart default — safer in most cases."
  type        = string
  default     = ""
}

variable "controller_replicas" {
  description = "Number of controller replicas. Two replicas with leader election is the recommended HA configuration; a single replica is fine for dev clusters."
  type        = number
  default     = 2

  validation {
    condition     = var.controller_replicas >= 1 && var.controller_replicas <= 5
    error_message = "controller_replicas must be between 1 and 5."
  }
}

variable "controller_resources" {
  description = "CPU/memory requests and limits for the controller pod. Defaults are tuned for a cluster with up to ~50 ALB-backed Ingresses; bump for larger fleets."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "100m", memory = "200Mi" }
    limits   = { cpu = "500m", memory = "500Mi" }
  }
}

variable "log_level" {
  description = "Log verbosity (info, debug, error). Use debug only when troubleshooting — debug logs include request bodies."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["info", "debug", "error", "warn"], var.log_level)
    error_message = "log_level must be one of info, debug, warn, error."
  }
}

variable "ingress_class" {
  description = "Default IngressClass name the controller will reconcile. The chart will create the IngressClass and IngressClassParams resources."
  type        = string
  default     = "alb"
}

variable "create_ingress_class_resource" {
  description = "Whether to let the chart create the IngressClass + IngressClassParams. Set false if those are managed by GitOps."
  type        = bool
  default     = true
}

variable "enable_shield" {
  description = "Whether the controller should enable AWS Shield Advanced on managed ALBs. Requires Shield Advanced subscription on the account."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Whether the controller should reconcile WAF Classic associations on managed ALBs."
  type        = bool
  default     = false
}

variable "enable_wafv2" {
  description = "Whether the controller should reconcile WAFv2 associations on managed ALBs (most users want this true)."
  type        = bool
  default     = true
}

variable "default_tags" {
  description = "Tags to add to every AWS resource the controller creates (target groups, listeners, ALBs)."
  type        = map(string)
  default     = {}
}

variable "node_selector" {
  description = "Node selector for controller pods. Defaults to placing them on system nodes alongside other addons."
  type        = map(string)
  default = {
    workload = "system"
  }
}

variable "tolerations" {
  description = "Tolerations applied to controller pods. The default tolerates the CriticalAddonsOnly taint used by the system node group."
  type = list(object({
    key      = string
    operator = string
    value    = optional(string)
    effect   = optional(string)
  }))
  default = [
    {
      key      = "CriticalAddonsOnly"
      operator = "Exists"
    }
  ]
}

variable "tags" {
  description = "Tags applied to every AWS resource this module creates (IAM role, IAM policy)."
  type        = map(string)
  default     = {}
}
