# =============================================================================
# OUTPUTS
# =============================================================================

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.retail_app_eks.cluster_endpoint
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.retail_app_eks.cluster_name
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.retail_app_eks.cluster_name}"
}

output "argocd_initial_password_command" {
  description = "Command to retrieve ArgoCD initial admin password"
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
}