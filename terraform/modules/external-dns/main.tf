###############################################################################
# ExternalDNS — IRSA + IAM policy + Helm release.
#
# ExternalDNS reconciles Kubernetes Ingress / Service / Gateway records into
# Route 53 hosted zones. It does this by:
#
#   1. Listing Kubernetes resources of the kinds in `sources`.
#   2. Extracting host names from `host:` (Ingress) or
#      `external-dns.alpha.kubernetes.io/hostname` annotations (Service).
#   3. Creating one A / AAAA / ALIAS record per host pointing at the
#      load balancer DNS name.
#   4. Maintaining a parallel TXT "registry" record so the controller can
#      tell which records it owns and safely clean up ones whose source
#      has been deleted.
#
# This module:
#
#   * Builds an IRSA role whose IAM policy is *zone-scoped* — no
#     `route53:ChangeResourceRecordSets` on `*`. The list of allowed zones
#     is `var.hosted_zone_ids`.
#   * Deploys ExternalDNS via the official Helm chart.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  irsa_role_name  = "external-dns-${var.cluster_name}"
  iam_policy_name = "external-dns-${var.cluster_name}-policy"

  # Default the TXT owner to the cluster name; this is what lets multiple
  # clusters share a single hosted zone.
  effective_txt_owner = var.txt_owner_id != "" ? var.txt_owner_id : "external-dns-${var.cluster_name}"

  # Pre-compute the zone ARNs for the IAM policy. These are partition-aware
  # so the same module works in GovCloud / China when the partition var is
  # configured at the provider level.
  zone_arns = [
    for zone_id in var.hosted_zone_ids :
    "arn:${local.partition}:route53:::hostedzone/${zone_id}"
  ]

  common_tags = merge(var.tags, {
    Module    = "external-dns"
    Cluster   = var.cluster_name
    ManagedBy = "terraform"
  })
}

###############################################################################
# (1) IRSA role.
###############################################################################

data "aws_iam_policy_document" "controller_assume" {
  statement {
    sid     = "AllowExternalDNSPodToAssumeRole"
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
  description        = "IRSA role for ExternalDNS in cluster ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
  tags               = local.common_tags
}

###############################################################################
# (2) IAM policy — minimum-privilege for ExternalDNS on Route 53.
#
# Only `route53:ChangeResourceRecordSets` is restricted to specific zones;
# the *List* APIs require `Resource: "*"` because the AWS API doesn't
# support per-zone scoping for them. That's still safe — listing zones is
# read-only.
###############################################################################

data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "Route53ChangeRecords"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = local.zone_arns
  }

  statement {
    sid    = "Route53ListZones"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "controller" {
  name        = local.iam_policy_name
  description = "Route 53 zone-scoped permissions for ExternalDNS in ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.controller.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

###############################################################################
# (3) Helm release.
###############################################################################

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = var.chart_repository
  chart            = "external-dns"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      provider = "aws"

      sources = var.sources

      # Zone-id-filters narrows which zones the controller will ENUMERATE,
      # while domain-filters narrows which records it will RECONCILE. The
      # combination is belt-and-braces: even if the IAM policy were too
      # permissive, ExternalDNS still wouldn't touch records outside the
      # listed domains/zones.
      zoneIdFilters = var.hosted_zone_ids
      domainFilters = var.domain_filters
      excludeDomains = var.exclude_domains

      policy   = var.policy
      registry = "txt"

      txtOwnerId = local.effective_txt_owner

      # The TXT prefix avoids collision with users' own TXT records. Pattern
      # _externaldns.<recordname>.<zone> is widely supported by other DNS
      # tooling.
      txtPrefix = "_externaldns."

      interval = var.interval

      logLevel  = var.log_level
      logFormat = "json"

      serviceAccount = {
        create = true
        name   = var.service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.controller.arn
        }
      }

      env = [{
        name  = "AWS_DEFAULT_REGION"
        value = data.aws_caller_identity.current.account_id != "" ? "" : ""
      }]

      image = {
        registry = var.image_registry
      }

      resources = {
        requests = var.controller_resources.requests
        limits   = var.controller_resources.limits
      }

      nodeSelector = var.node_selector
      tolerations  = var.tolerations

      # ExternalDNS is single-active by default — only one replica should
      # write to Route 53 at a time. The chart enforces this via leader
      # election when replicaCount > 1.
      replicaCount = 1

      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 65534
        fsGroup      = 65534
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      securityContext = {
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        capabilities = {
          drop = ["ALL"]
        }
      }

      # Liveness + readiness on /healthz at the chart default port.
      livenessProbe = {
        initialDelaySeconds = 10
        timeoutSeconds      = 5
      }

      readinessProbe = {
        initialDelaySeconds = 5
        timeoutSeconds      = 5
      }

      # PrometheusServiceMonitor — flip on when the operator is installed
      # (Day 44 in this repo's roadmap).
      serviceMonitor = {
        enabled = false
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.controller,
  ]
}
