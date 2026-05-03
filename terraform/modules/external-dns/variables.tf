###############################################################################
# ExternalDNS module — input variables.
#
# This module provisions ExternalDNS to reconcile Kubernetes Ingress / Service
# objects into Route 53 records. It produces:
#
#   * IRSA role with the minimum Route 53 permissions, scoped to the listed
#     hosted zones (no `*` resource on `route53:ChangeResourceRecordSets`).
#   * Helm release of the ExternalDNS chart from the official repository.
#
# Domain filtering is the most important variable to set correctly: leaving
# `domain_filters` empty lets ExternalDNS act on every record in every zone
# the role is allowed to touch — which is rarely what you want.
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster the controller serves. Embedded in the txt-owner-id so multiple clusters can share a hosted zone safely."
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
  description = "List of Route 53 hosted zone IDs ExternalDNS is allowed to manage. The IAM policy is scoped to these zones; do not pass `*` here. Use `data.aws_route53_zone` to look the IDs up by name."
  type        = list(string)

  validation {
    condition     = length(var.hosted_zone_ids) > 0
    error_message = "Provide at least one hosted_zone_id. Empty list = ExternalDNS does nothing useful."
  }

  validation {
    condition     = alltrue([for z in var.hosted_zone_ids : can(regex("^Z[0-9A-Z]+$", z))])
    error_message = "hosted_zone_ids must be Route 53 hosted-zone IDs starting with Z (e.g. Z1ABC23DEF456G)."
  }
}

variable "domain_filters" {
  description = "DNS suffixes ExternalDNS should reconcile. Records outside these suffixes are ignored, even if the IAM policy would permit them. Example: [\"example.com\", \"internal.example.net\"]."
  type        = list(string)

  validation {
    condition     = length(var.domain_filters) > 0
    error_message = "Provide at least one domain_filter. Empty filter = act on every record in every zone the role can touch — a foot-gun."
  }
}

variable "exclude_domains" {
  description = "DNS suffixes to explicitly EXCLUDE even if they fall under domain_filters. Useful for protecting a critical apex record from accidental deletion."
  type        = list(string)
  default     = []
}

variable "txt_owner_id" {
  description = "Owner ID written into ExternalDNS TXT registry records to identify which controller owns a record. Defaults to `external-dns-${cluster_name}` so multiple clusters can share a hosted zone without stomping each other's records."
  type        = string
  default     = ""
}

variable "policy" {
  description = "ExternalDNS sync policy: `sync` (create + update + delete), `upsert-only` (create + update, never delete), or `create-only`. `upsert-only` is the safest default — turn on `sync` only when you're confident."
  type        = string
  default     = "upsert-only"

  validation {
    condition     = contains(["sync", "upsert-only", "create-only"], var.policy)
    error_message = "policy must be one of sync, upsert-only, create-only."
  }
}

variable "sources" {
  description = "Kubernetes resource kinds ExternalDNS will watch. The default covers Ingress and Service — add `crd` if using gateway-api or contour HTTPProxy."
  type        = list(string)
  default     = ["service", "ingress"]
}

variable "namespace" {
  description = "Kubernetes namespace where ExternalDNS runs."
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Name of the ServiceAccount used by ExternalDNS pods."
  type        = string
  default     = "external-dns"
}

variable "chart_repository" {
  description = "Helm repository hosting the ExternalDNS chart. The official chart is at https://kubernetes-sigs.github.io/external-dns/."
  type        = string
  default     = "https://kubernetes-sigs.github.io/external-dns/"
}

variable "chart_version" {
  description = "Helm chart version. Pin to make `terraform plan` reproducible."
  type        = string
  default     = "1.14.5"
}

variable "image_registry" {
  description = "Container image registry override. Use the AWS public ECR mirror to avoid Docker Hub rate limits."
  type        = string
  default     = "registry.k8s.io"
}

variable "controller_resources" {
  description = "Resource requests + limits for the controller pod."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "50m",  memory = "100Mi" }
    limits   = { cpu = "200m", memory = "200Mi" }
  }
}

variable "log_level" {
  description = "Log level (debug, info, warn, error)."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of debug, info, warn, error."
  }
}

variable "interval" {
  description = "Reconciliation interval. ExternalDNS calls Route 53 ListResourceRecordSets every interval — shorter = faster reaction to record drift, longer = lower API cost."
  type        = string
  default     = "1m"
}

variable "node_selector" {
  description = "Node selector for ExternalDNS pods."
  type        = map(string)
  default = {
    workload = "system"
  }
}

variable "tolerations" {
  description = "Tolerations applied to ExternalDNS pods. Defaults tolerate the system-node CriticalAddonsOnly taint."
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
