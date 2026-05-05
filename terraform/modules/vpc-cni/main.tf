###############################################################################
# Amazon VPC CNI — managed addon configuration with prefix delegation.
#
# The Amazon VPC CNI plugin (`aws-node` DaemonSet) gives every pod a routable
# VPC IP. Out of the box on EKS this is fine, but the *default* configuration
# limits pod density per node to a small multiple tied to the instance's ENI
# count (e.g. m5.large → 29 pods). For modern workloads that's wasteful.
#
# Two features unlock more pods per node:
#
#   1. PREFIX DELEGATION (`ENABLE_PREFIX_DELEGATION=true`).
#      Each ENI is assigned /28 IPv4 prefixes (16 IPs each) instead of one
#      secondary IP at a time. On nitro instances this multiplies pod
#      capacity by ~10×: m5.large jumps from 29 to ~110 pods, m5.4xlarge
#      goes from ~233 to the kubelet's 250-pod ceiling.
#      Trade-off: VPC CIDR consumption is chunkier — plan subnets in
#      /22 or larger to leave room.
#
#   2. CUSTOM NETWORKING (`AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true`).
#      Pods are assigned IPs from secondary CIDRs attached to the VPC,
#      separate from the node's primary CIDR. Lets you back nodes with a
#      small RFC 1918 range and pods with a much larger 100.64/10 range
#      to escape IP exhaustion. Requires `ENIConfig` CRDs per AZ — we
#      install the CRD via the addon and document the per-AZ
#      `ENIConfig` resources in the addon-reference doc.
#
# Other tunings:
#   * `WARM_PREFIX_TARGET=1` — keep one /28 prefix warm per ENI.
#   * `ENABLE_POD_ENI=true` — required for security-group-per-pod (SGP).
#   * `POD_SECURITY_GROUP_ENFORCING_MODE=standard` — strict iptables
#     enforcement of pod-level security groups.
#
# IRSA is provided so the CNI can assume a dedicated role with the
# `AmazonEKS_CNI_Policy` managed policy. We additionally allow IPv6 ENI
# tagging permissions for forward compatibility.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition

  irsa_role_name = "vpc-cni-${var.cluster_name}"
  sa_subject     = "system:serviceaccount:${var.namespace}:${var.service_account_name}"

  common_tags = merge(var.tags, {
    Module    = "vpc-cni"
    Cluster   = var.cluster_name
    ManagedBy = "terraform"
  })
}

###############################################################################
# (1) IRSA role for the aws-node DaemonSet.
#
# Moving CNI off the node instance profile (where it sits by default in a
# fresh EKS cluster) lets you tighten the node role — strip
# `AmazonEKS_CNI_Policy` from it once this addon's IRSA is in place.
###############################################################################

data "aws_iam_policy_document" "cni_assume" {
  statement {
    sid     = "AllowVpcCniToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_host}:sub"
      values   = [local.sa_subject]
    }
  }
}

resource "aws_iam_role" "cni" {
  name               = local.irsa_role_name
  description        = "IRSA role for the VPC CNI DaemonSet (aws-node) in cluster ${var.cluster_name}."
  assume_role_policy = data.aws_iam_policy_document.cni_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.cni.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# IPv6-only side: required for IPv6 clusters and harmless on IPv4 — no
# additional permissions exist that would surprise an auditor.
resource "aws_iam_role_policy_attachment" "ipv6" {
  count      = var.enable_ipv6_policy ? 1 : 0
  role       = aws_iam_role.cni.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_IPv6_Policy"
}

###############################################################################
# (2) The EKS managed addon.
#
# `configuration_values` is the VPC CNI's chart-style config schema. The
# full schema is published at:
#   https://github.com/aws/amazon-vpc-cni-k8s/blob/master/charts/aws-vpc-cni/values.yaml
#
# We set env vars that flip on prefix delegation, security groups for pods,
# and (optionally) custom networking.
###############################################################################

resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = var.cluster_name
  addon_name               = "vpc-cni"
  addon_version            = var.addon_version
  service_account_role_arn = aws_iam_role.cni.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = merge(
      {
        # Prefix delegation: assign /28 IPv4 prefixes per ENI -> ~10× pods.
        ENABLE_PREFIX_DELEGATION = tostring(var.enable_prefix_delegation)
        WARM_PREFIX_TARGET       = tostring(var.warm_prefix_target)
        WARM_IP_TARGET           = tostring(var.warm_ip_target)

        # Security-group-per-pod toggle. Requires nitro instances.
        ENABLE_POD_ENI                    = tostring(var.enable_pod_eni)
        POD_SECURITY_GROUP_ENFORCING_MODE = var.pod_security_group_enforcing_mode

        # Custom networking: pods get IPs from secondary VPC CIDRs via
        # ENIConfig CRDs. Node still uses primary CIDR.
        AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = tostring(var.enable_custom_networking)
        ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"

        # External SNAT — set true when pods route outbound via a NAT Gateway
        # in a public subnet. Disable when using AWS_VPC_K8S_CNI_EXTERNALSNAT
        # with a transit gateway egress.
        AWS_VPC_K8S_CNI_EXTERNALSNAT = tostring(var.external_snat)

        # CNI logs: file destination + log level. file destination keeps
        # `/var/log/aws-routed-eni/plugin.log` populated even if the CNI
        # itself crashes — invaluable for post-mortems.
        AWS_VPC_K8S_CNI_LOG_FILE = "/host/var/log/aws-routed-eni/plugin.log"
        AWS_VPC_K8S_CNI_LOGLEVEL = var.log_level

        # Disable the netpol agent here — Cilium / Calico are installed
        # separately for network policy. Set to true to use the built-in
        # NetworkPolicy controller instead.
        ENABLE_NETWORK_POLICY = tostring(var.enable_network_policy)
      },
      var.extra_env,
    )
    nodeAgent = {
      enabled = var.enable_network_policy
      enablePolicyEventLogs = var.enable_network_policy
    }
    init = {
      env = {
        DISABLE_TCP_EARLY_DEMUX = "false"
      }
    }
  })

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.cni,
    aws_iam_role_policy_attachment.ipv6,
  ]
}
