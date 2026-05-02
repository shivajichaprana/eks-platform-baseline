###############################################################################
# Karpenter — IAM (IRSA), EC2 instance profile, SQS interruption queue,
# EventBridge rules.
#
# This file provisions everything Karpenter needs *outside* Helm:
#
#   1. An IRSA role for the Karpenter controller to call EC2 / IAM / SQS APIs.
#   2. An EC2 instance profile that wraps the worker-node role from the eks
#      module — Karpenter places this profile on every node it launches.
#   3. An SQS queue that receives EC2 spot-interruption, scheduled-event, and
#      AZ-rebalance notifications via EventBridge. The controller drains
#      affected nodes ~2 minutes before AWS reclaims them.
#   4. EventBridge rules forwarding the relevant event patterns into that SQS
#      queue.
#
# All of these resources are tagged with the cluster name so a single AWS
# account can host multiple clusters managed by Karpenter without collision.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  irsa_role_name        = "karpenter-controller-${var.cluster_name}"
  instance_profile_name = "KarpenterNodeInstanceProfile-${var.cluster_name}"
  interruption_queue    = "karpenter-${var.cluster_name}"

  # Discovery tag — Karpenter EC2NodeClasses use these tags as selectors when
  # looking up subnets and security groups. The eks module already tags its
  # subnets and SGs with `karpenter.sh/discovery = <cluster_name>`; if not,
  # add the tags before applying this module.
  discovery_tag_key   = "karpenter.sh/discovery"
  discovery_tag_value = var.cluster_name

  common_tags = merge(var.tags, {
    Module                                                  = "karpenter"
    Cluster                                                 = var.cluster_name
    "karpenter.sh/discovery"                                = var.cluster_name
    "kubernetes.io/cluster/${var.cluster_name}"             = "owned"
  })
}

###############################################################################
# (1) IRSA role — assumed by the Karpenter controller pod via its
# ServiceAccount. Trust policy scopes the assumption to *exactly* this
# cluster's OIDC provider + the karpenter SA name in the karpenter namespace.
###############################################################################

data "aws_iam_policy_document" "controller_assume" {
  statement {
    sid     = "KarpenterControllerAssumeRole"
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
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = local.irsa_role_name
  description        = "IRSA role for the Karpenter controller in cluster ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
  tags               = local.common_tags
}

###############################################################################
# Controller permissions — the published Karpenter "controller policy" pared
# down so we don't grant `iam:PassRole` on `*`. We constrain PassRole to the
# worker-node role of this cluster only.
#
# Reference: https://karpenter.sh/docs/reference/cloudformation/
###############################################################################

data "aws_iam_policy_document" "controller" {
  # EC2 — describe + run/launch/terminate instances Karpenter manages
  statement {
    sid    = "AllowEC2ReadActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstances",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeSpotPriceHistory",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowScopedEC2InstanceAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = [
      "arn:${local.partition}:ec2:${local.region}::image/*",
      "arn:${local.partition}:ec2:${local.region}::snapshot/*",
      "arn:${local.partition}:ec2:${local.region}:*:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:*:subnet/*",
    ]
  }

  statement {
    sid    = "AllowScopedEC2LaunchTemplateAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
    ]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:launch-template/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.discovery_tag_key}"
      values   = [local.discovery_tag_value]
    }
  }

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
    ]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:volume/*",
      "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.discovery_tag_key}"
      values   = [local.discovery_tag_value]
    }
  }

  statement {
    sid       = "AllowScopedResourceCreationTagging"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:*/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateLaunchTemplate", "RunInstances", "CreateFleet"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.discovery_tag_key}"
      values   = [local.discovery_tag_value]
    }
  }

  statement {
    sid    = "AllowScopedResourceTagging"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
    ]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.discovery_tag_key}"
      values   = [local.discovery_tag_value]
    }
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.discovery_tag_key}"
      values   = [local.discovery_tag_value]
    }
  }

  # Pricing — Karpenter uses the pricing API to choose the cheapest instance
  # type that fits a pending pod's resource requests.
  statement {
    sid       = "AllowPricing"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  # SSM — used to look up the latest AMI for AL2023 / Bottlerocket families.
  statement {
    sid       = "AllowSSMReadActions"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}::parameter/aws/service/*"]
  }

  # IAM — pass the node role onto launched instances. We constrain PassRole
  # to *this* cluster's node role only.
  statement {
    sid       = "AllowPassingInstanceRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.node_iam_role_name}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid     = "AllowInstanceProfileActions"
    effect  = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
  }

  # EKS — discover the cluster's API endpoint and CA on startup.
  statement {
    sid       = "AllowEKSReadActions"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name}"]
  }

  # SQS — drain the interruption queue.
  dynamic "statement" {
    for_each = var.node_termination_handler_enabled ? [1] : []
    content {
      sid    = "AllowInterruptionQueueActions"
      effect = "Allow"
      actions = [
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
      ]
      resources = [aws_sqs_queue.interruption[0].arn]
    }
  }
}

resource "aws_iam_policy" "controller" {
  name        = "${local.irsa_role_name}-policy"
  description = "Permissions for the Karpenter controller in cluster ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.controller.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

###############################################################################
# (2) EC2 instance profile — Karpenter requires every launched node to use
# an instance profile, not a raw role. We wrap the worker-node role from the
# eks module here so the same trust + permissions apply to managed-node-group
# nodes and Karpenter-launched nodes.
###############################################################################

resource "aws_iam_instance_profile" "node" {
  name = local.instance_profile_name
  role = var.node_iam_role_name
  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# (3) SQS interruption queue — a single queue receives spot interruption,
# scheduled-event, instance-state-change, and AZ-rebalance notifications.
# Server-side encryption is enabled with the AWS-managed key. The 4-day
# retention covers the longest reasonable controller outage window.
###############################################################################

resource "aws_sqs_queue" "interruption" {
  count = var.node_termination_handler_enabled ? 1 : 0

  name                      = local.interruption_queue
  message_retention_seconds = 345600 # 4 days
  sqs_managed_sse_enabled   = true
  tags                      = local.common_tags
}

data "aws_iam_policy_document" "interruption_queue" {
  count = var.node_termination_handler_enabled ? 1 : 0

  statement {
    sid       = "EventBridgeWriteAccess"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.interruption[0].arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  count = var.node_termination_handler_enabled ? 1 : 0

  queue_url = aws_sqs_queue.interruption[0].url
  policy    = data.aws_iam_policy_document.interruption_queue[0].json
}

###############################################################################
# (4) EventBridge rules — forward EC2 lifecycle events of interest into the
# Karpenter SQS queue.
###############################################################################

locals {
  eventbridge_rules = var.node_termination_handler_enabled ? {
    spot_interruption = {
      description   = "Forward EC2 spot interruption warnings to Karpenter."
      event_pattern = jsonencode({
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Spot Instance Interruption Warning"]
      })
    }
    scheduled_change = {
      description   = "Forward EC2 scheduled change events (e.g. host retirements) to Karpenter."
      event_pattern = jsonencode({
        source        = ["aws.health"]
        "detail-type" = ["AWS Health Event"]
      })
    }
    instance_state_change = {
      description   = "Forward EC2 instance state changes to Karpenter so it reconciles when nodes go away unexpectedly."
      event_pattern = jsonencode({
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance State-change Notification"]
      })
    }
    rebalance_recommendation = {
      description   = "Forward AZ-rebalance recommendations so Karpenter can pre-empt impending interruptions."
      event_pattern = jsonencode({
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance Rebalance Recommendation"]
      })
    }
  } : {}
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.eventbridge_rules

  name          = "karpenter-${var.cluster_name}-${replace(each.key, "_", "-")}"
  description   = each.value.description
  event_pattern = each.value.event_pattern
  tags          = local.common_tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.eventbridge_rules

  rule      = aws_cloudwatch_event_rule.this[each.key].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption[0].arn
}
