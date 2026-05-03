###############################################################################
# AWS Load Balancer Controller — IRSA + IAM policy + Helm release.
#
# The AWS Load Balancer Controller (LBC, formerly aws-alb-ingress-controller)
# reconciles two Kubernetes resources into AWS load balancers:
#
#   * `Ingress` (with ingressClassName: alb) becomes an Application Load
#     Balancer with target groups, listeners, and rules per host/path.
#   * `Service type=LoadBalancer` (with a specific NLB annotation set)
#     becomes a Network Load Balancer.
#
# This module produces:
#
#   1. An IRSA role + dedicated IAM policy for the controller's pod identity.
#      The policy is the published "v2.7" controller policy from the AWS docs,
#      transcribed verbatim — pinned here so an `aws_iam_policy_document` plan
#      doesn't drift on every controller upgrade.
#   2. A Helm release of the chart from the official `eks-charts` repository.
#
# We do NOT create the ALB Subnet tags here — those belong to the VPC module
# (subnet must be tagged `kubernetes.io/role/elb=1` for public, or
# `kubernetes.io/role/internal-elb=1` for private). The vpc module already
# emits those tags.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  irsa_role_name   = "aws-lbc-${var.cluster_name}"
  iam_policy_name  = "aws-lbc-${var.cluster_name}-policy"

  common_tags = merge(var.tags, {
    Module    = "alb-controller"
    Cluster   = var.cluster_name
    ManagedBy = "terraform"
  })
}

###############################################################################
# (1) IRSA role — assumed by the controller pod via its ServiceAccount.
#
# The trust policy is scoped to this *exact* OIDC provider + namespace +
# ServiceAccount triple. That means the role can only be assumed by pods
# running with this SA in this cluster — a different cluster (with a
# different OIDC issuer) cannot assume it even if a pod with the same SA
# name exists there.
###############################################################################

data "aws_iam_policy_document" "controller_assume" {
  statement {
    sid     = "AllowLBCPodToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Audience must be sts.amazonaws.com — the default audience for IRSA.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Subject pins the role to *this* SA in *this* namespace.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = local.irsa_role_name
  description        = "IRSA role for the AWS Load Balancer Controller in cluster ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
  tags               = local.common_tags
}

###############################################################################
# (2) IAM policy — the published LBC controller policy.
#
# Source: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
#
# We embed the JSON inline rather than reading it from the file system so the
# module is self-contained. Update this string when bumping the chart major
# version. We leave the ELBv2 actions wide-open on resources because the
# controller needs to manage every ALB/NLB it creates and the AWS resource
# naming pattern doesn't allow precise ARN scoping.
###############################################################################

resource "aws_iam_policy" "controller" {
  name        = local.iam_policy_name
  description = "Permissions for the AWS Load Balancer Controller in cluster ${var.cluster_name}"
  tags        = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:${local.partition}:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          "Null" = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "arn:${local.partition}:ec2:*:*:security-group/*"
        Condition = {
          "Null" = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
        ]
        Resource = "*"
        Condition = {
          "Null" = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
        ]
        Resource = "*"
        Condition = {
          "Null" = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          "Null" = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:${local.partition}:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
        ]
        Resource = "*"
        Condition = {
          "Null" = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
        ]
        Resource = [
          "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = [
              "CreateTargetGroup",
              "CreateLoadBalancer",
            ]
          }
          "Null" = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
        ]
        Resource = "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

###############################################################################
# (3) Helm release.
#
# We deploy the controller from the official `eks-charts` repository. The
# values block here is the minimal set needed for the controller to call AWS
# correctly: cluster name + region + VPC ID + IRSA SA annotation. Workload
# placement (taints/tolerations + nodeSelector) defaults to the system node
# group; override `var.node_selector` / `var.tolerations` for clusters with
# different system-pod conventions.
###############################################################################

resource "helm_release" "lbc" {
  name             = "aws-load-balancer-controller"
  repository       = var.chart_repository
  chart            = "aws-load-balancer-controller"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false # kube-system always exists

  # Block on rollout completion so apply fails fast on IRSA / image pull
  # problems instead of leaving a half-installed release.
  wait    = true
  timeout = 600

  values = [
    yamlencode({
      replicaCount = var.controller_replicas

      clusterName = var.cluster_name
      region      = var.region
      vpcId       = var.vpc_id

      serviceAccount = {
        create = true
        name   = var.service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.controller.arn
        }
      }

      # The chart's IngressClass + IngressClassParams resources. Set false
      # only when these are managed by GitOps.
      createIngressClassResource = var.create_ingress_class_resource
      ingressClass               = var.ingress_class

      # Feature flags wired straight into controller args.
      enableShield = var.enable_shield
      enableWaf    = var.enable_waf
      enableWafv2  = var.enable_wafv2

      # Default tags applied to every AWS resource the controller manages.
      defaultTags = var.default_tags

      logLevel = var.log_level

      image = var.controller_image_tag != "" ? {
        tag = var.controller_image_tag
      } : null

      resources = {
        requests = var.controller_resources.requests
        limits   = var.controller_resources.limits
      }

      # Pin controller pods to the system node group; the controller cannot
      # manage Ingress for itself if it gets scheduled onto a Karpenter-
      # provisioned spot node that is later interrupted.
      nodeSelector = var.node_selector
      tolerations  = var.tolerations

      affinity = {
        # Spread replicas across nodes for HA.
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              topologyKey = "kubernetes.io/hostname"
              labelSelector = {
                matchExpressions = [{
                  key      = "app.kubernetes.io/name"
                  operator = "In"
                  values   = ["aws-load-balancer-controller"]
                }]
              }
            }
          }]
        }
      }

      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "topology.kubernetes.io/zone"
        whenUnsatisfiable = "ScheduleAnyway"
        labelSelector = {
          matchLabels = {
            "app.kubernetes.io/name" = "aws-load-balancer-controller"
          }
        }
      }]

      podDisruptionBudget = {
        maxUnavailable = 1
      }

      # Pod-level security context — runAsNonRoot, drop everything.
      podSecurityContext = {
        runAsNonRoot = true
        fsGroup      = 65534
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      securityContext = {
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        runAsNonRoot             = true
        capabilities = {
          drop = ["ALL"]
        }
      }

      # Liveness + readiness probes are enabled by default in the chart at
      # /healthz on port 61779 — no override needed.

      # Webhook certificate management is handled by the chart's built-in
      # cert-gen Job (no cert-manager dependency for the webhook itself).
      enableCertManager = false

      # Enable PrometheusServiceMonitor when an operator is installed.
      serviceMonitor = {
        enabled = false
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.controller,
  ]
}
