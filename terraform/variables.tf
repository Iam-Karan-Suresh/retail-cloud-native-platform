# =============================================================================
# INPUT VARIABLES
# =============================================================================

variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "retail-store"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "argocd_namespace" {
  description = "Namespace to install ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "9.5.13"
}

variable "enable_single_nat_gateway" {
  description = "Use single NAT gateway to reduce costs (not recommended for production)"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Enable open-source monitoring stack (Prometheus, Grafana) to avoid expensive CloudWatch costs"
  type        = bool
  default     = true
}

# =============================================================================
# SPOT INSTANCE CONFIGURATION
# =============================================================================

variable "spot_instance_types" {
  description = "List of instance types for spot worker nodes. Diversity reduces interruption probability."
  type        = list(string)
  default = [
    "t3.medium", "t3.large", "t3.xlarge",
    "t3a.medium", "t3a.large", "t3a.xlarge",
    "m5.large", "m5.xlarge",
    "m5a.large", "m5a.xlarge"
  ]
}

variable "spot_min_size" {
  description = "Minimum number of spot worker nodes"
  type        = number
  default     = 2
}

variable "spot_max_size" {
  description = "Maximum number of spot worker nodes (ASG ceiling)"
  type        = number
  default     = 20
}

variable "spot_desired_size" {
  description = "Desired number of spot worker nodes"
  type        = number
  default     = 3
}
