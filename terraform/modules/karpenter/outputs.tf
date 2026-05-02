###############################################################################
# Karpenter module — outputs.
###############################################################################

output "controller_role_arn" {
  description = "IRSA role ARN bound to the Karpenter controller ServiceAccount."
  value       = aws_iam_role.controller.arn
}

output "controller_role_name" {
  description = "IRSA role name bound to the Karpenter controller ServiceAccount."
  value       = aws_iam_role.controller.name
}

output "node_instance_profile_name" {
  description = "Name of the EC2 instance profile that Karpenter places on every node it launches. Reference this in the EC2NodeClass.spec.role field (Karpenter resolves it to this profile)."
  value       = aws_iam_instance_profile.node.name
}

output "node_instance_profile_arn" {
  description = "ARN of the Karpenter node instance profile."
  value       = aws_iam_instance_profile.node.arn
}

output "interruption_queue_name" {
  description = "Name of the SQS queue receiving spot interruption + scheduled change events. Empty when node_termination_handler_enabled is false."
  value       = var.node_termination_handler_enabled ? aws_sqs_queue.interruption[0].name : ""
}

output "interruption_queue_arn" {
  description = "ARN of the SQS interruption queue. Empty when disabled."
  value       = var.node_termination_handler_enabled ? aws_sqs_queue.interruption[0].arn : ""
}

output "namespace" {
  description = "Kubernetes namespace where the Karpenter controller runs."
  value       = var.namespace
}

output "service_account_name" {
  description = "Name of the Karpenter ServiceAccount."
  value       = var.service_account_name
}

output "chart_version" {
  description = "Karpenter Helm chart version that was deployed."
  value       = helm_release.karpenter.version
}

output "discovery_tag" {
  description = "Tag key/value used by EC2NodeClass selectors to find subnets and security groups belonging to this cluster."
  value = {
    key   = "karpenter.sh/discovery"
    value = var.cluster_name
  }
}
