###############################################################################
# EKS module — outputs
###############################################################################

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes minor version of the control plane"
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA. Feed into kubeconfig."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "The security group EKS auto-creates and attaches to control-plane ENIs."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "additional_cluster_security_group_id" {
  description = "Additional cluster security group provisioned by this module."
  value       = aws_security_group.cluster_additional.id
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN that the EKS control plane assumes."
  value       = aws_iam_role.cluster.arn
}

###############################################################################
# IRSA outputs — consumed by every Day-2 addon module.
###############################################################################

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster (https://...)."
  value       = local.oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA."
  value       = local.oidc_provider_arn
}

output "oidc_provider_host" {
  description = "OIDC issuer URL with the leading https:// stripped — useful when building an IAM trust policy condition (oidc_provider_host:sub)."
  value       = local.oidc_provider_host
}

###############################################################################
# Node group outputs.
###############################################################################

output "system_node_group_name" {
  description = "Name of the system managed node group."
  value       = aws_eks_node_group.system.node_group_name
}

output "system_node_group_arn" {
  description = "ARN of the system managed node group."
  value       = aws_eks_node_group.system.arn
}

output "node_iam_role_name" {
  description = "Name of the worker-node IAM role. Karpenter (Day 38) will reuse this role for its EC2NodeClass."
  value       = aws_iam_role.node.name
}

output "node_iam_role_arn" {
  description = "ARN of the worker-node IAM role."
  value       = aws_iam_role.node.arn
}
