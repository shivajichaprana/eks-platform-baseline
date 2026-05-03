###############################################################################
# AWS Load Balancer Controller — outputs.
###############################################################################

output "controller_role_arn" {
  description = "IRSA role ARN bound to the controller ServiceAccount. Useful when wiring Ingress CRDs that reference an SA in the same namespace."
  value       = aws_iam_role.controller.arn
}

output "controller_role_name" {
  description = "IRSA role name for the controller."
  value       = aws_iam_role.controller.name
}

output "controller_policy_arn" {
  description = "ARN of the inline-equivalent IAM policy attached to the controller role."
  value       = aws_iam_policy.controller.arn
}

output "namespace" {
  description = "Kubernetes namespace the controller runs in."
  value       = var.namespace
}

output "service_account_name" {
  description = "Name of the controller ServiceAccount."
  value       = var.service_account_name
}

output "ingress_class" {
  description = "IngressClass name reconciled by this controller. Reference this in Ingress.spec.ingressClassName."
  value       = var.ingress_class
}

output "chart_version" {
  description = "Helm chart version that was deployed."
  value       = helm_release.lbc.version
}

output "release_name" {
  description = "Helm release name. Useful when scripting `helm get values` / `helm rollback`."
  value       = helm_release.lbc.name
}
