###############################################################################
# cert-manager module — input variables.
#
# This module deploys cert-manager and the IAM role needed for its Route 53
# DNS-01 solver. cert-manager itself is provisioned by Helm; the
# ClusterIssuer manifests live under `manifests/cert-manager/` and are
# applied separately (kubectl apply, Argo, Flux). They're separated so
# Terraform isn't forced into the GitOps loop.
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster cert-manager runs in. Embedded in IAM resource names so a single AWS account can host multiple clusters."
  type        = string

  validation {
    condition     = length(var.cluster_name) > 0 && length(var.cluster_name) <= 100
    error_message = "cluster_name must be between 1 and 100 characters."
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA (eks module output)."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC issuer host with the leading https:// stripped (eks module output)."
  type        = string
}

variable "hosted_zone_ids" {
  description = "List of Route 53 hosted zone IDs cert-manager is allowed to write to for DNS-01 challenges. Scope this tightly — leaking this role lets an attacker rewrite TXT records in those zones."
  type        = list(string)

  validation {
    condition     = length(var.hosted_zone_ids) > 0
    error_message = "Provide at least one hosted_zone_id. Without one, the DNS-01 solver can't issue certs."
  }

  validation {
    condition     = alltrue([for z in var.hosted_zone_ids : can(regex("^Z[0-9A-Z]+$", z))])
    error_message = "hosted_zone_ids must be Route 53 hosted-zone IDs starting with Z."
  }
}

variable "namespace" {
  description = "Kubernetes namespace where cert-manager runs. cert-manager hard-codes some defaults (webhook service DNS) on `cert-manager` so the default is what the chart expects."
  type        = string
  default     = "cert-manager"
}

variable "service_account_name" {
  description = "Name of the cert-manager controller ServiceAccount. The chart uses `cert-manager` by default."
  type        = string
  default     = "cert-manager"
}

variable "chart_repository" {
  description = "Helm repository hosting the cert-manager chart. Official chart at https://charts.jetstack.io."
  type        = string
  default     = "https://charts.jetstack.io"
}

variable "chart_version" {
  description = "Helm chart version for cert-manager. Pin to make plan reproducible."
  type        = string
  default     = "v1.15.1"
}

variable "install_crds" {
  description = "Whether the chart should install cert-manager CRDs. Set false only if CRDs are managed separately (e.g. by GitOps with sync-wave 0)."
  type        = bool
  default     = true
}

variable "controller_replicas" {
  description = "Number of cert-manager controller replicas. Recommended HA value is 2 with leader election."
  type        = number
  default     = 2

  validation {
    condition     = var.controller_replicas >= 1 && var.controller_replicas <= 5
    error_message = "controller_replicas must be between 1 and 5."
  }
}

variable "webhook_replicas" {
  description = "Replicas for the cert-manager webhook. Two ensures availability during rolling updates."
  type        = number
  default     = 2

  validation {
    condition     = var.webhook_replicas >= 1 && var.webhook_replicas <= 5
    error_message = "webhook_replicas must be between 1 and 5."
  }
}

variable "cainjector_replicas" {
  description = "Replicas for the cert-manager CA injector."
  type        = number
  default     = 2

  validation {
    condition     = var.cainjector_replicas >= 1 && var.cainjector_replicas <= 5
    error_message = "cainjector_replicas must be between 1 and 5."
  }
}

variable "controller_resources" {
  description = "Resource requests and limits for cert-manager controller pods."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "50m",  memory = "128Mi" }
    limits   = { cpu = "200m", memory = "256Mi" }
  }
}

variable "log_level" {
  description = "Log verbosity (1-6, higher = more verbose)."
  type        = number
  default     = 2

  validation {
    condition     = var.log_level >= 1 && var.log_level <= 6
    error_message = "log_level must be between 1 and 6."
  }
}

variable "node_selector" {
  description = "Node selector for cert-manager pods."
  type        = map(string)
  default = {
    workload = "system"
  }
}

variable "tolerations" {
  description = "Tolerations applied to cert-manager pods."
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
  description = "Tags applied to AWS resources (IAM role + policy)."
  type        = map(string)
  default     = {}
}
