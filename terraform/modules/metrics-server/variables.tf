###############################################################################
# metrics-server module — input variables.
###############################################################################

variable "namespace" {
  description = "Kubernetes namespace where metrics-server runs. kube-system is the documented default and is what HPA expects."
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Name of the metrics-server ServiceAccount."
  type        = string
  default     = "metrics-server"
}

variable "chart_repository" {
  description = "Helm repository hosting the metrics-server chart."
  type        = string
  default     = "https://kubernetes-sigs.github.io/metrics-server/"
}

variable "chart_version" {
  description = "Helm chart version. Pin to make `terraform plan` reproducible."
  type        = string
  default     = "3.12.1"
}

variable "replicas" {
  description = "Replica count for the metrics-server Deployment. 2 is the practical minimum for HA — HPA depends on this being responsive."
  type        = number
  default     = 2

  validation {
    condition     = var.replicas >= 1 && var.replicas <= 5
    error_message = "replicas must be between 1 and 5."
  }
}

variable "metric_resolution" {
  description = "Scrape interval for kubelet metrics. 15s is the documented default; lower means HPA reacts faster but adds kubelet CPU cost."
  type        = string
  default     = "15s"

  validation {
    condition     = can(regex("^[0-9]+(s|ms)$", var.metric_resolution))
    error_message = "metric_resolution must look like `15s` or `5000ms`."
  }
}

variable "kubelet_insecure_tls" {
  description = "If true, metrics-server skips TLS verification of kubelet certificates. Required for legacy clusters with self-signed kubelet certs. Modern EKS/Bottlerocket nodes do NOT need this."
  type        = bool
  default     = false
}

variable "resources" {
  description = "Resource requests + limits for the metrics-server pod. metrics-server is light — defaults handle ~5000 pods comfortably."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "100m", memory = "200Mi" }
    limits   = { cpu = "500m", memory = "500Mi" }
  }
}

variable "node_selector" {
  description = "Node selector applied to the metrics-server pod. Pin to system nodes."
  type        = map(string)
  default = {
    workload = "system"
  }
}

variable "tolerations" {
  description = "Tolerations applied to the metrics-server pod."
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

variable "extra_args" {
  description = "Additional CLI arguments to pass to metrics-server. Use sparingly — most knobs are surfaced as variables."
  type        = list(string)
  default     = []
}
