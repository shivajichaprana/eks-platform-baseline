###############################################################################
# cert-manager — IRSA + IAM policy + Helm release.
#
# cert-manager handles X.509 certificate issuance. We wire it up to use the
# Route 53 DNS-01 solver against ACME endpoints (Let's Encrypt). DNS-01 is
# preferred over HTTP-01 here because:
#
#   * It works for hostnames not yet served by an Ingress (or behind
#     internal-only ALBs).
#   * It supports wildcards (`*.example.com`).
#   * No public Internet path to a solver pod is required.
#
# This module produces:
#
#   1. An IRSA role + Route-53-zone-scoped IAM policy for the cert-manager
#      controller pod. The trust policy is wired to `cert-manager` /
#      `cert-manager` (namespace + SA), the chart's defaults.
#   2. A Helm release of the cert-manager chart from `charts.jetstack.io`.
#
# The actual ClusterIssuers (Let's Encrypt prod + staging) are *not* created
# in Terraform — they're shipped as YAML under `manifests/cert-manager/` and
# applied via kubectl/GitOps after `terraform apply` succeeds. This keeps
# Terraform out of the renewals path: cert-manager handles those by reading
# its own CRDs.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  irsa_role_name  = "cert-manager-${var.cluster_name}"
  iam_policy_name = "cert-manager-${var.cluster_name}-policy"

  # zone-scoped Route 53 ARNs.
  zone_arns = [
    for zone_id in var.hosted_zone_ids :
    "arn:${local.partition}:route53:::hostedzone/${zone_id}"
  ]

  common_tags = merge(var.tags, {
    Module    = "cert-manager"
    Cluster   = var.cluster_name
    ManagedBy = "terraform"
  })
}

###############################################################################
# (1) IRSA role for cert-manager controller.
#
# Note: cert-manager has multiple SAs (controller, webhook, cainjector). Only
# the controller SA needs Route 53 access — the webhook and cainjector
# don't make AWS API calls.
###############################################################################

data "aws_iam_policy_document" "controller_assume" {
  statement {
    sid     = "AllowCertManagerControllerToAssumeRole"
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

    # Trust only the controller SA in the cert-manager namespace. The
    # webhook + cainjector SAs are explicitly NOT in this list.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = local.irsa_role_name
  description        = "IRSA role for the cert-manager controller in cluster ${var.cluster_name}. Scoped to Route 53 DNS-01 challenges only."
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
  tags               = local.common_tags
}

###############################################################################
# (2) IAM policy — minimum-privilege for DNS-01 ACME challenges.
#
# cert-manager DNS-01 needs:
#   * route53:GetChange — poll the propagation status of TXT changes
#   * route53:ChangeResourceRecordSets — create/delete _acme-challenge TXT
#   * route53:ListHostedZonesByName — locate the zone for a hostname
#
# The change action is scoped to the listed hosted zones only.
###############################################################################

data "aws_iam_policy_document" "controller" {
  # Required for the TXT-propagation polling loop.
  statement {
    sid       = "Route53GetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:${local.partition}:route53:::change/*"]
  }

  # Solver needs to write _acme-challenge TXT records into the listed zones
  # ONLY. This is the high-blast-radius permission so we keep it tight.
  statement {
    sid       = "Route53ChangeRecordSets"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = local.zone_arns
  }

  # Listing zones can't be scoped to specific zones in the AWS API, so we
  # allow read-only metadata access. cert-manager only reads.
  statement {
    sid    = "Route53ListZones"
    effect = "Allow"
    actions = [
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "controller" {
  name        = local.iam_policy_name
  description = "Route 53 DNS-01 challenge permissions for cert-manager in ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.controller.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

###############################################################################
# (3) Helm release.
#
# cert-manager's chart deploys three Deployments — controller, webhook,
# cainjector. We size them all for HA on a real cluster; trim the replica
# counts for dev environments.
###############################################################################

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = var.chart_repository
  chart            = "cert-manager"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      # Install CRDs in-chart unless explicitly disabled. Required for the
      # ClusterIssuer / Certificate / Issuer / CertificateRequest CRDs.
      crds = {
        enabled = var.install_crds
        keep    = true # don't delete CRDs on chart uninstall
      }

      replicaCount = var.controller_replicas

      # Controller pod — the one that needs Route 53 access.
      serviceAccount = {
        create = true
        name   = var.service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.controller.arn
        }
      }

      # Set the dns01-recursive-nameserver to a public resolver so the
      # solver doesn't get the cluster's CoreDNS view (which won't see
      # public TXT records during propagation).
      extraArgs = [
        "--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53",
        "--dns01-recursive-nameservers-only",
      ]

      logLevel = var.log_level

      resources = {
        requests = var.controller_resources.requests
        limits   = var.controller_resources.limits
      }

      nodeSelector = var.node_selector
      tolerations  = var.tolerations

      # Pod-level securityContext applied chart-wide.
      securityContext = {
        runAsNonRoot = true
        runAsUser    = 1001
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      containerSecurityContext = {
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        runAsNonRoot             = true
        capabilities = {
          drop = ["ALL"]
        }
      }

      # Webhook tier — handles validation + mutation hooks for cert-manager
      # CRDs. The webhook itself uses cert-gen to bootstrap its TLS, no
      # external CA needed.
      webhook = {
        replicaCount = var.webhook_replicas
        resources = {
          requests = { cpu = "10m", memory = "32Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
        nodeSelector = var.node_selector
        tolerations  = var.tolerations
        securityContext = {
          runAsNonRoot = true
          runAsUser    = 1001
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }
        containerSecurityContext = {
          allowPrivilegeEscalation = false
          readOnlyRootFilesystem   = true
          runAsNonRoot             = true
          capabilities = {
            drop = ["ALL"]
          }
        }
      }

      # CA injector — injects the cert-manager CA bundle into validating /
      # mutating webhooks that opt-in via annotation.
      cainjector = {
        replicaCount = var.cainjector_replicas
        resources = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
        nodeSelector = var.node_selector
        tolerations  = var.tolerations
        securityContext = {
          runAsNonRoot = true
          runAsUser    = 1001
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }
        containerSecurityContext = {
          allowPrivilegeEscalation = false
          readOnlyRootFilesystem   = true
          runAsNonRoot             = true
          capabilities = {
            drop = ["ALL"]
          }
        }
      }

      # Spread replicas across nodes for HA.
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              topologyKey = "kubernetes.io/hostname"
              labelSelector = {
                matchExpressions = [{
                  key      = "app.kubernetes.io/name"
                  operator = "In"
                  values   = ["cert-manager"]
                }]
              }
            }
          }]
        }
      }

      podDisruptionBudget = {
        enabled        = true
        maxUnavailable = 1
      }

      # Prometheus scrape — turn on once the operator is present.
      prometheus = {
        enabled = true
        servicemonitor = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.controller,
  ]
}
