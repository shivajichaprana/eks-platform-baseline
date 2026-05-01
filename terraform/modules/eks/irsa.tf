###############################################################################
# IRSA (IAM Roles for Service Accounts)
#
# Provisions the IAM OIDC identity provider that lets pods assume IAM roles via
# their service-account token. Every Day-2 addon module (ALB Controller,
# ExternalDNS, EBS CSI, Karpenter, etc.) attaches its IAM role's trust policy
# to this OIDC provider.
###############################################################################

# Pull the cluster's OIDC issuer URL — exposed once the cluster is up.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-oidc"
  })
}

# Convenience locals exposed via outputs so addon modules can build trust
# policy documents without re-deriving the OIDC URL each time.
locals {
  oidc_issuer_url    = aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_provider_arn  = aws_iam_openid_connect_provider.this.arn
  oidc_provider_host = replace(local.oidc_issuer_url, "https://", "")
}
