# =============================================================================
# OUTPUTS
# =============================================================================

# ---------------------------------------------------------------------------
# CLUSTER ACCESS
# ---------------------------------------------------------------------------

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.retail_app_eks.cluster_endpoint
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.retail_app_eks.cluster_name
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.retail_app_eks.cluster_version
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.retail_app_eks.cluster_name}"
}

# ---------------------------------------------------------------------------
# ARGOCD
# ---------------------------------------------------------------------------

output "argocd_initial_password_command" {
  description = "Command to retrieve ArgoCD initial admin password"
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
}

# ---------------------------------------------------------------------------
# SPOT TERMINATION / KARPENTER
# ---------------------------------------------------------------------------

output "spot_termination_sqs_queue_url" {
  description = "SQS queue URL for spot termination events (consumed by Karpenter)"
  value       = aws_sqs_queue.node_termination.url
}

output "spot_termination_sqs_queue_arn" {
  description = "SQS queue ARN for spot termination events (consumed by Karpenter)"
  value       = aws_sqs_queue.node_termination.arn
}

output "karpenter_iam_role_arn" {
  description = "IAM role ARN used by Karpenter controller via IRSA"
  value       = module.karpenter_irsa.iam_role_arn
}

# ---------------------------------------------------------------------------
# NETWORKING
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs where worker nodes run"
  value       = module.vpc.private_subnets
}