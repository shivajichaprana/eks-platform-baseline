###############################################################################
# EKS module — control plane
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

###############################################################################
# Cluster IAM role
###############################################################################

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name_prefix        = "${var.cluster_name}-cluster-"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_eks" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_resource" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
}

###############################################################################
# Cluster security group — additional, EKS will create its own as well.
###############################################################################

resource "aws_security_group" "cluster_additional" {
  name_prefix = "${var.cluster_name}-cluster-add-"
  description = "Additional security group attached to the EKS cluster ENIs"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-cluster-add"
  })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Control-plane log group — pre-create so we can set retention. EKS will
# happily reuse an existing log group with the canonical name.
###############################################################################

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

###############################################################################
# The cluster itself
###############################################################################

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.endpoint_public_cidrs : null
    security_group_ids      = [aws_security_group.cluster_additional.id]
  }

  # Use the IAM authentication mode that supports EKS Access Entries (the
  # post-aws-auth ConfigMap world). API_AND_CONFIG_MAP is the safe default
  # while older tooling still expects the ConfigMap to exist.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(var.tags, {
    Name = var.cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks,
    aws_iam_role_policy_attachment.cluster_vpc_resource,
    aws_cloudwatch_log_group.cluster,
  ]

  lifecycle {
    # Cluster recreation is destructive; require an explicit state move.
    ignore_changes = [bootstrap_self_managed_addons]
  }
}
