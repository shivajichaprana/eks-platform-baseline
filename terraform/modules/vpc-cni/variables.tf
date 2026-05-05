###############################################################################
# VPC CNI module — input variables.
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster the addon is installed into."
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

  validation {
    condition     = !startswith(var.oidc_provider_host, "https://")
    error_message = "oidc_provider_host must NOT include the https:// prefix — pass the host portion only."
  }
}

variable "addon_version" {
  description = "Pinned EKS addon version for vpc-cni. Use `aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version <ver>` to look up valid values."
  type        = string
  default     = "v1.18.2-eksbuild.1"
}

variable "namespace" {
  description = "Kubernetes namespace where the aws-node ServiceAccount lives."
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Name of the aws-node ServiceAccount the IRSA role trusts. Always `aws-node` for the managed addon — exposed only for tests."
  type        = string
  default     = "aws-node"
}

variable "enable_prefix_delegation" {
  description = "If true, each ENI is assigned /28 IPv4 prefixes (16 IPs each) instead of single secondary IPs — boosts pods-per-node by ~10× on Nitro instances. Plan subnets in /22+ to leave room."
  type        = bool
  default     = true
}

variable "warm_prefix_target" {
  description = "Number of /28 prefixes the CNI keeps warm per ENI when prefix delegation is enabled. 1 is the recommended default — higher values reserve more IPs but cushion against bursts in pod creation."
  type        = number
  default     = 1

  validation {
    condition     = var.warm_prefix_target >= 0 && var.warm_prefix_target <= 5
    error_message = "warm_prefix_target must be between 0 and 5."
  }
}

variable "warm_ip_target" {
  description = "Number of warm IPs to keep available per node. With prefix delegation this is per-prefix (so 5 → 5 IPs from the warm prefix). Set to 0 when prefix delegation is on."
  type        = number
  default     = 0
}

variable "enable_pod_eni" {
  description = "If true, allows SecurityGroupPolicy CRDs to attach security groups per pod (SGP). Requires Nitro-based instances. Adds a slight pod-startup latency cost."
  type        = bool
  default     = true
}

variable "pod_security_group_enforcing_mode" {
  description = "Security group enforcement mode when pod ENIs are enabled. `standard` enforces via iptables (strict). `strict` is reserved for legacy."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "strict"], var.pod_security_group_enforcing_mode)
    error_message = "pod_security_group_enforcing_mode must be standard or strict."
  }
}

variable "enable_custom_networking" {
  description = "If true, the CNI assigns pod IPs from secondary VPC CIDRs via per-AZ ENIConfig CRDs (NOT the node's primary CIDR). Use to back nodes with a small RFC 1918 range and pods with a 100.64.0.0/10 range to escape IP exhaustion. ENIConfigs must be applied separately."
  type        = bool
  default     = false
}

variable "external_snat" {
  description = "If true, the CNI does NOT SNAT pod-egress traffic (useful when egress goes via a NAT Gateway or Transit Gateway that handles SNAT itself). Default false matches the standard NAT-Gateway-per-AZ topology."
  type        = bool
  default     = false
}

variable "log_level" {
  description = "CNI log level. DEBUG is verbose — flip on temporarily for troubleshooting, then revert."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARN", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARN, ERROR."
  }
}

variable "enable_network_policy" {
  description = "If true, enables the built-in VPC CNI NetworkPolicy controller (eBPF-based, k8s 1.25+). Disable when running Cilium or Calico for policy."
  type        = bool
  default     = false
}

variable "enable_ipv6_policy" {
  description = "Whether to attach AmazonEKS_CNI_IPv6_Policy to the IRSA role. Safe to leave on for IPv4 clusters (no extra surface)."
  type        = bool
  default     = true
}

variable "extra_env" {
  description = "Map of additional env vars to merge into the addon configuration. Useful for one-off knobs not surfaced as variables."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to AWS resources (IAM role + addon)."
  type        = map(string)
  default     = {}
}
