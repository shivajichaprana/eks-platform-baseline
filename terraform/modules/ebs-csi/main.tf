###############################################################################
# EBS CSI driver — managed addon + IRSA + default gp3 StorageClass.
#
# AWS publishes the EBS CSI driver as an EKS managed addon. Compared with the
# self-managed Helm-chart install, the managed addon:
#
#   * Is upgraded by EKS (we still pin a specific addon_version below so a
#     drift only happens if we change it intentionally).
#   * Has its CRDs and webhooks managed by AWS — no schema-conversion grief
#     across upgrades.
#   * Picks up an IRSA role via the addon's `service_account_role_arn` field,
#     so we don't have to patch the SA out-of-band.
#
# This module produces:
#
#   1. An IRSA role for the controller pod, trust scoped to the EKS cluster
#      OIDC + the `kube-system/ebs-csi-controller-sa` ServiceAccount.
#   2. The IAM policy required by the driver. We attach the AWS-managed
#      `AmazonEBSCSIDriverPolicy` (the supported approach) PLUS a small
#      inline policy for KMS, scoped to the encryption key passed in.
#   3. The `aws-ebs-csi-driver` EKS addon.
#   4. A default gp3 StorageClass via the kubernetes provider, so any PVC
#      created without an explicit `storageClassName` lands on encrypted
#      gp3 with WaitForFirstConsumer binding.
#
# StorageClass design notes:
#   * gp3 over gp2 — same price baseline, configurable IOPS/throughput, and
#     consistent performance regardless of volume size.
#   * `volumeBindingMode: WaitForFirstConsumer` — the volume is provisioned
#     in the same AZ as the pod that ends up scheduling, instead of being
#     created up front in an AZ no pod ends up in. This avoids the classic
#     "PV pinned to AZ A, pod can only schedule in AZ B" deadlock.
#   * `allowVolumeExpansion: true` — `kubectl edit pvc` to grow online.
#   * `reclaimPolicy: Delete` — if the PVC is deleted, the underlying EBS
#     volume is too. Override at the PVC level for stateful apps.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  irsa_role_name        = "ebs-csi-${var.cluster_name}"
  kms_inline_policy_nm  = "ebs-csi-${var.cluster_name}-kms"
  controller_sa_subject = "system:serviceaccount:${var.namespace}:${var.controller_service_account}"

  common_tags = merge(var.tags, {
    Module    = "ebs-csi"
    Cluster   = var.cluster_name
    ManagedBy = "terraform"
  })
}

###############################################################################
# (1) IRSA role for the EBS CSI controller pod.
#
# Note: the *node* DaemonSet pods do not need an IRSA role — they run with
# the node's instance profile and call only EC2 metadata + local kubelet
# APIs. The controller is the one that calls CreateVolume, AttachVolume,
# DescribeVolumes, etc.
###############################################################################

data "aws_iam_policy_document" "controller_assume" {
  statement {
    sid     = "AllowEbsCsiControllerToAssumeRole"
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
      values   = [local.controller_sa_subject]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = local.irsa_role_name
  description        = "IRSA role for the EBS CSI controller in cluster ${var.cluster_name}."
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
  tags               = local.common_tags
}

###############################################################################
# (2) IAM policy attachments.
#
# The AWS-managed `AmazonEBSCSIDriverPolicy` covers EC2 calls (create,
# attach, detach, describe, snapshot, modify). It does NOT cover the KMS
# permissions required when the StorageClass uses a customer-managed key —
# we add those inline, scoped to the supplied key ARN.
###############################################################################

resource "aws_iam_role_policy_attachment" "managed" {
  role       = aws_iam_role.controller.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# KMS inline policy is attached only when a CMK ARN is provided.
data "aws_iam_policy_document" "kms" {
  count = var.kms_key_arn == null ? 0 : 1

  # Permissions the driver needs against the CMK to provision encrypted
  # volumes. `CreateGrant` is what allows the EBS service to use the key
  # on the volume's behalf during attach/detach.
  statement {
    sid    = "AllowEbsCsiToUseCmk"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "AllowEbsCsiToCreateGrants"
    effect    = "Allow"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = [var.kms_key_arn]
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "kms" {
  count = var.kms_key_arn == null ? 0 : 1

  name   = local.kms_inline_policy_nm
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.kms[0].json
}

###############################################################################
# (3) The EKS managed addon.
#
# `resolve_conflicts_on_*` set to OVERWRITE so an existing self-managed
# install (pre-addon) gets adopted cleanly, and version drifts during
# `terraform apply` are reconciled to what we declare here.
###############################################################################

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = var.addon_version
  service_account_role_arn = aws_iam_role.controller.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    controller = {
      replicaCount = var.controller_replicas
      resources    = var.controller_resources
      nodeSelector = var.controller_node_selector
      tolerations  = var.controller_tolerations
    }
    node = {
      tolerateAllTaints = true
    }
    sidecars = {
      provisioner = {
        additionalArgs = ["--feature-gates=Topology=true"]
      }
    }
  })

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.managed,
    aws_iam_role_policy.kms,
  ]
}

###############################################################################
# (4) Default gp3 StorageClass.
#
# Created via the kubernetes provider so it lives in Terraform state — if
# someone deletes it from the cluster a `terraform apply` brings it back.
#
# Annotated as the cluster default (`storageclass.kubernetes.io/is-default-class`)
# so PVCs without an explicit `storageClassName` use it.
###############################################################################

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = var.default_storage_class_name
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "eks-platform-baseline"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = merge(
    {
      type       = "gp3"
      iops       = tostring(var.gp3_iops)
      throughput = tostring(var.gp3_throughput_mibps)
      encrypted  = "true"
      # Pass through filesystem hint so dynamically-provisioned volumes are
      # mkfs'd with the desired filesystem.
      "csi.storage.k8s.io/fstype" = var.gp3_fstype
    },
    var.kms_key_arn == null ? {} : { kmsKeyId = var.kms_key_arn },
  )

  depends_on = [aws_eks_addon.ebs_csi]
}
