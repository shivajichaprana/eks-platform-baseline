###############################################################################
# metrics-server module — outputs.
###############################################################################

output "release_name" {
  description = "Name of the Helm release."
  value       = helm_release.metrics_server.name
}

output "release_namespace" {
  description = "Namespace the release is installed into."
  value       = helm_release.metrics_server.namespace
}

output "chart_version" {
  description = "Chart version installed — useful to assert in tests / drift checks."
  value       = helm_release.metrics_server.version
}
