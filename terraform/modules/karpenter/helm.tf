###############################################################################
# Karpenter — Helm release.
#
# We deploy the Karpenter controller from the official OCI registry
# (oci://public.ecr.aws/karpenter/karpenter). The values here are the minimal
# set to make the controller talk to the SQS queue and the cluster API; per-
# workload tuning lives in the NodePool / EC2NodeClass manifests under
# `manifests/karpenter/`.
#
# The kubernetes provider isn't used directly — Helm renders the chart's own
# CRDs (`karpenter.sh/NodePool`, `karpenter.k8s.aws/EC2NodeClass`). Apply the
# manifests under `manifests/karpenter/` *after* `terraform apply` finishes;
# they require the CRDs to exist first.
###############################################################################

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  # Wait for the controller to become ready before terraform considers the
  # release applied. Helps catch IRSA misconfigurations early.
  wait    = true
  timeout = 600

  # The Helm chart names CRDs are immutable after install; if a previous
  # apply created them, Helm will skip CRD upgrades and we surface that as a
  # warning rather than a hard failure.
  skip_crds = false

  values = [
    yamlencode({
      replicas = var.controller_replicas

      serviceAccount = {
        create = var.create_service_account
        name   = var.service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.controller.arn
        }
      }

      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = var.node_termination_handler_enabled ? aws_sqs_queue.interruption[0].name : ""
        # featureGates left at chart defaults — flip these per-version when
        # promoting to GA. See the karpenter release notes.
      }

      controller = {
        resources = {
          requests = var.controller_resources.requests
          limits   = var.controller_resources.limits
        }
      }

      logLevel = var.log_level

      # Pin the Karpenter pods to the system node group: the controller
      # cannot place itself on the very nodes it provisions, otherwise we get
      # a chicken-and-egg problem during cluster bootstrap.
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Exists"
      }]

      nodeSelector = {
        workload = "system"
      }

      affinity = {
        # Spread the two replicas across nodes for HA.
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            topologyKey = "kubernetes.io/hostname"
            labelSelector = {
              matchExpressions = [{
                key      = "app.kubernetes.io/name"
                operator = "In"
                values   = ["karpenter"]
              }]
            }
          }]
        }
      }

      # Topology spread is more permissive than anti-affinity — it allows
      # placement on a single node if there's no alternative, which keeps
      # bootstrapping unblocked.
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = "ScheduleAnyway"
        labelSelector = {
          matchLabels = {
            "app.kubernetes.io/name" = "karpenter"
          }
        }
      }]

      podDisruptionBudget = {
        name           = "karpenter"
        maxUnavailable = 1
      }

      # Pod-level securityContext — runAsNonRoot, drop all capabilities.
      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 65532
        fsGroup      = 65532
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
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.controller,
    aws_iam_instance_profile.node,
  ]
}
