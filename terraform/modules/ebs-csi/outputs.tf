###############################################################################
# EBS CSI module — outputs.
###############################################################################

output "irsa_role_arn" {
  description = "ARN of the IRSA role assumed by the EBS CSI controller pod. Useful for asserting in tests that the SA was annotated correctly."
  value       = aws_iam_role.controller.arn
}

output "irsa_role_name" {
  description = "Name of the IRSA role for the EBS CSI controller."
  value       = aws_iam_role.controller.name
}

output "addon_arn" {
  description = "ARN of the EKS addon resource."
  value       = aws_eks_addon.ebs_csi.arn
}

output "addon_version" {
  description = "Version of the aws-ebs-csi-driver addon currently installed."
  value       = aws_eks_addon.ebs_csi.addon_version
}

output "default_storage_class_name" {
  description = "Name of the default StorageClass created by this module. Other modules / manifests can reference this when they need to opt in explicitly."
  value       = kubernetes_storage_class_v1.gp3.metadata[0].name
}
