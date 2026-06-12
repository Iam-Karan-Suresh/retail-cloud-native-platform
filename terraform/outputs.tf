# =============================================================================
# OUTPUTS
# =============================================================================

# =============================================================================
# NETWORK INFORMATION
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}


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

output "cluster_name_base" {
  description = "Base cluster name without suffix"
  value       = var.cluster_name
}

output "cluster_name_suffix" {
  description = "Random suffix added to cluster name"
  value       = random_string.suffix.result
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.retail_app_eks.cluster_version
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.retail_app_eks.cluster_name}"
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.retail_app_eks.cluster_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster for the OpenID Connect identity provider"
  value       = module.retail_app_eks.cluster_oidc_issuer_url
}

# ---------------------------------------------------------------------------
# ARGOCD
# ---------------------------------------------------------------------------

output "argocd_initial_password_command" {
  description = "Command to retrieve ArgoCD initial admin password"
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
  sensitive = true
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = var.argocd_namespace
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = var.argocd_namespace
}


output "argocd_server_port_forward" {
  description = "Command to port-forward to ArgoCD server"
  value       = "kubectl port-forward svc/argocd-server -n ${var.argocd_namespace} 8080:443"
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

output "useful_commands" {
  description = "Useful commands for managing the cluster"
  value       = {
    get_nodes           = "kubectl get nodes"
    get_pods_all        = "kubectl get pods -A"
    get_retail_store    = "kubectl get pods -n retail-store"
    argocd_apps         = "kubectl get applications -n ${var.argocd_namespace}"
    describe_cluster    = "kubectl cluster-info"
  } 
}