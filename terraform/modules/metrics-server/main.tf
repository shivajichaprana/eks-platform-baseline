###############################################################################
# metrics-server — provides container/node CPU + memory metrics for the
# kubelet → kube-apiserver `metrics.k8s.io` API.
#
# WHAT IT POWERS
#   * `kubectl top pod` / `kubectl top node`
#   * HorizontalPodAutoscaler (HPA) v1 / v2 on CPU + memory.
#   * VerticalPodAutoscaler recommender (when running VPA).
#
# metrics-server is NOT a long-term metrics store — it scrapes pods every
# scrape interval and discards old data. For dashboards / alerts, ship
# metrics to Prometheus / AMP (handled by `aws-observability-stack`).
#
# DEPLOYMENT NOTES
#   * Installed via the official Helm chart from `kubernetes-sigs`.
#   * Pinned to the system node group via nodeSelector + toleration.
#   * 2 replicas with a PodDisruptionBudget so HPA keeps working during
#     control-plane upgrades or node drains.
#   * `--kubelet-insecure-tls` is OFF — Bottlerocket / AL2 nodes ship a
#     trusted kubelet cert by default. Flip to true only for legacy
#     clusters with self-signed kubelet certs.
#   * `--kubelet-preferred-address-types=InternalIP` — avoids DNS lookups
#     and `Hostname` resolution issues on private clusters.
###############################################################################

resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  namespace        = var.namespace
  repository       = var.chart_repository
  chart            = "metrics-server"
  version          = var.chart_version
  create_namespace = false
  atomic           = true
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      replicas = var.replicas

      args = concat(
        [
          "--cert-dir=/tmp",
          "--secure-port=10250",
          "--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP",
          "--kubelet-use-node-status-port",
          "--metric-resolution=${var.metric_resolution}",
        ],
        var.kubelet_insecure_tls ? ["--kubelet-insecure-tls"] : [],
        var.extra_args,
      )

      resources = var.resources

      podDisruptionBudget = {
        enabled        = true
        minAvailable   = 1
      }

      # Anti-affinity so the two replicas do not co-locate on the same node.
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [
            {
              labelSelector = {
                matchExpressions = [
                  {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["metrics-server"]
                  },
                ]
              }
              topologyKey = "kubernetes.io/hostname"
            },
          ]
        }
      }

      # Pin to system node group so user-workload Karpenter pools don't
      # run kube-system addons.
      nodeSelector = var.node_selector

      tolerations = var.tolerations

      # Probes — metrics-server's own /healthz and /readyz are reliable.
      livenessProbe = {
        httpGet = {
          path   = "/livez"
          port   = "https"
          scheme = "HTTPS"
        }
        initialDelaySeconds = 30
        periodSeconds       = 10
        failureThreshold    = 3
      }

      readinessProbe = {
        httpGet = {
          path   = "/readyz"
          port   = "https"
          scheme = "HTTPS"
        }
        initialDelaySeconds = 20
        periodSeconds       = 10
        failureThreshold    = 3
      }

      # SecurityContext — non-root, read-only filesystem, drop all caps.
      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 1000
        seccompProfile = {
          type = "RuntimeDefault"
        }
      }

      containerSecurityContext = {
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        capabilities = {
          drop = ["ALL"]
        }
      }

      serviceAccount = {
        create = true
        name   = var.service_account_name
        labels = {
          "app.kubernetes.io/managed-by" = "terraform"
          "app.kubernetes.io/part-of"    = "eks-platform-baseline"
        }
      }

      # APIService registration — metrics-server registers itself as the
      # `v1beta1.metrics.k8s.io` APIService. Disable here only if you've
      # registered something else (rare).
      apiService = {
        create = true
        insecureSkipTLSVerify = false
      }

      # Add baseline labels to the chart's resources so they're easy to
      # find / select on.
      commonLabels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "eks-platform-baseline"
        "addon"                        = "metrics-server"
      }
    }),
  ]
}
