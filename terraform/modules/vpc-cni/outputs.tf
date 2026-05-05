###############################################################################
# VPC CNI module — outputs.
###############################################################################

output "irsa_role_arn" {
  description = "ARN of the IRSA role assumed by the aws-node DaemonSet."
  value       = aws_iam_role.cni.arn
}

output "irsa_role_name" {
  description = "Name of the IRSA role for the VPC CNI."
  value       = aws_iam_role.cni.name
}

output "addon_arn" {
  description = "ARN of the vpc-cni EKS addon."
  value       = aws_eks_addon.vpc_cni.arn
}

output "addon_version" {
  description = "Version of the vpc-cni addon currently installed."
  value       = aws_eks_addon.vpc_cni.addon_version
}

output "prefix_delegation_enabled" {
  description = "True if prefix delegation is enabled for this addon — useful for plan-output assertions."
  value       = var.enable_prefix_delegation
}
