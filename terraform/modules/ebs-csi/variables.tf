###############################################################################
# EBS CSI module — input variables.
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster the addon is installed into. Used to scope IAM resource names."
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
  description = "Pinned EKS addon version for aws-ebs-csi-driver. Use `aws eks describe-addon-versions --addon-name aws-ebs-csi-driver --kubernetes-version <ver>` to look up valid values. Pinning here means a `terraform apply` will not silently bump the driver."
  type        = string
  default     = "v1.32.0-eksbuild.1"
}

variable "namespace" {
  description = "Kubernetes namespace where the addon's ServiceAccounts live. Always kube-system for the managed addon — exposed only for tests."
  type        = string
  default     = "kube-system"
}

variable "controller_service_account" {
  description = "Name of the controller ServiceAccount the IRSA role trusts."
  type        = string
  default     = "ebs-csi-controller-sa"
}

variable "node_service_account" {
  description = "Name of the node DaemonSet ServiceAccount. The node SA does NOT have an IRSA role; it uses the node instance profile instead. Exposed for downstream automation that needs the SA name."
  type        = string
  default     = "ebs-csi-node-sa"
}

variable "kms_key_arn" {
  description = "Optional ARN of a customer-managed KMS key used to encrypt EBS volumes provisioned by the default StorageClass. Pass `null` to use the AWS-managed `aws/ebs` key — encryption stays on, but you don't get IAM-level revocation control. Recommended: use a CMK so you can rotate / revoke / audit."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[-a-z]*:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a valid KMS key ARN (arn:aws:kms:...) or null."
  }
}

variable "controller_replicas" {
  description = "Replica count for the EBS CSI controller Deployment. 2 is enough for HA — the leader-elected controller calls EC2 APIs serially anyway."
  type        = number
  default     = 2

  validation {
    condition     = var.controller_replicas >= 1 && var.controller_replicas <= 5
    error_message = "controller_replicas must be between 1 and 5."
  }
}

variable "controller_resources" {
  description = "Resource requests + limits for the controller pod. The driver is mostly idle — it spikes during volume provisioning bursts."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "10m", memory = "40Mi" }
    limits   = { cpu = "100m", memory = "256Mi" }
  }
}

variable "controller_node_selector" {
  description = "Node selector for the controller pod. Defaults pin the controller to system nodes."
  type        = map(string)
  default = {
    workload = "system"
  }
}

variable "controller_tolerations" {
  description = "Tolerations applied to the controller pod. Defaults tolerate the system-node CriticalAddonsOnly taint."
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

variable "default_storage_class_name" {
  description = "Name of the default StorageClass created by this module."
  type        = string
  default     = "gp3"
}

variable "gp3_iops" {
  description = "Provisioned IOPS for gp3 volumes. gp3 baseline is 3000 IOPS regardless of size; raise this for IO-heavy workloads (max 16000)."
  type        = number
  default     = 3000

  validation {
    condition     = var.gp3_iops >= 3000 && var.gp3_iops <= 16000
    error_message = "gp3_iops must be between 3000 and 16000."
  }
}

variable "gp3_throughput_mibps" {
  description = "Provisioned throughput in MiB/s for gp3 volumes. gp3 baseline is 125 MiB/s; raise for streaming workloads (max 1000)."
  type        = number
  default     = 125

  validation {
    condition     = var.gp3_throughput_mibps >= 125 && var.gp3_throughput_mibps <= 1000
    error_message = "gp3_throughput_mibps must be between 125 and 1000."
  }
}

variable "gp3_fstype" {
  description = "Filesystem the CSI driver should format dynamically-provisioned volumes with."
  type        = string
  default     = "ext4"

  validation {
    condition     = contains(["ext4", "xfs"], var.gp3_fstype)
    error_message = "gp3_fstype must be ext4 or xfs."
  }
}

variable "tags" {
  description = "Tags applied to AWS resources (IAM role + addon)."
  type        = map(string)
  default     = {}
}
