###############################################################################
# ExternalDNS module — outputs.
###############################################################################

output "controller_role_arn" {
  description = "IRSA role ARN bound to the ExternalDNS ServiceAccount."
  value       = aws_iam_role.controller.arn
}

output "controller_role_name" {
  description = "IRSA role name bound to the ExternalDNS ServiceAccount."
  value       = aws_iam_role.controller.name
}

output "controller_policy_arn" {
  description = "ARN of the zone-scoped IAM policy attached to the ExternalDNS role."
  value       = aws_iam_policy.controller.arn
}

output "namespace" {
  description = "Kubernetes namespace ExternalDNS runs in."
  value       = var.namespace
}

output "service_account_name" {
  description = "Name of the ExternalDNS ServiceAccount."
  value       = var.service_account_name
}

output "txt_owner_id" {
  description = "Owner ID written to TXT registry records. Use this when migrating between clusters or when ExternalDNS records appear orphaned."
  value       = local.effective_txt_owner
}

output "managed_zone_ids" {
  description = "Hosted zone IDs the controller is permitted to manage."
  value       = var.hosted_zone_ids
}

output "chart_version" {
  description = "Helm chart version that was deployed."
  value       = helm_release.external_dns.version
}
