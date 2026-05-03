###############################################################################
# cert-manager module — outputs.
###############################################################################

output "controller_role_arn" {
  description = "IRSA role ARN annotated on the cert-manager controller ServiceAccount. Reference this from any out-of-band tooling that needs to assume into the same Route 53 zone scope."
  value       = aws_iam_role.controller.arn
}

output "controller_role_name" {
  description = "IRSA role name for the cert-manager controller."
  value       = aws_iam_role.controller.name
}

output "controller_policy_arn" {
  description = "ARN of the zone-scoped Route 53 IAM policy attached to the cert-manager role."
  value       = aws_iam_policy.controller.arn
}

output "namespace" {
  description = "Kubernetes namespace cert-manager runs in. Reference this when applying ClusterIssuer manifests so the SA-binding annotations match."
  value       = var.namespace
}

output "service_account_name" {
  description = "Name of the cert-manager controller ServiceAccount that holds the IRSA annotation."
  value       = var.service_account_name
}

output "managed_zone_ids" {
  description = "Hosted zone IDs the controller is permitted to write _acme-challenge TXT records to."
  value       = var.hosted_zone_ids
}

output "chart_version" {
  description = "Helm chart version that was deployed."
  value       = helm_release.cert_manager.version
}
