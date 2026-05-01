###############################################################################
# System managed node group
#
# A small, taint-isolated node group dedicated to system workloads (CoreDNS,
# kube-proxy, metrics-server, addon controllers). Application workloads should
# land on Karpenter-provisioned capacity (Day 38 onwards) and tolerate the
# CriticalAddonsOnly taint they will set on these nodes.
###############################################################################

###############################################################################
# Node IAM role
###############################################################################

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${var.cluster_name}-node-"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

# AWS-managed policies required by every EKS worker node. We deliberately
# attach the legacy CNI policy here so the cluster comes up healthy even
# before IRSA-mode CNI is wired in (Day 40 swaps it onto a service-account).
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM Session Manager — replaces SSH bastions for emergency node access.
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

###############################################################################
# Launch template — gives us a tagged ENI, a custom disk size, and the ability
# to roll node configuration without breaking the node-group resource itself.
###############################################################################

resource "aws_launch_template" "system" {
  name_prefix = "${var.cluster_name}-system-"
  description = "Launch template for the EKS system managed node group"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.system_node_group.disk_size_gib
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # enforce IMDSv2
    http_put_response_hop_limit = 2          # required for in-pod IMDSv2 access
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true # CloudWatch detailed monitoring (1-min metrics)
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name                                        = "${var.cluster_name}-system-node"
      "eks:cluster-name"                          = var.cluster_name
      "eks:nodegroup-name"                        = "${var.cluster_name}-system"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-system-node-volume"
    })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# The managed node group
###############################################################################

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = var.system_node_group.desired_size
    min_size     = var.system_node_group.min_size
    max_size     = var.system_node_group.max_size
  }

  update_config {
    max_unavailable_percentage = 33
  }

  instance_types = var.system_node_group.instance_types
  capacity_type  = var.system_node_group.capacity_type

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  labels = var.system_node_group.labels

  dynamic "taint" {
    for_each = var.system_node_group.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-system"
  })

  # Roll nodes when the launch template changes (e.g. AMI bumps via
  # `aws_ssm_parameter` in a future iteration) without changing this resource.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_ssm,
  ]
}
