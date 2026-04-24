# =============================================================================
# MAIN INFRASTRUCTURE RESOURCES
# =============================================================================

# =============================================================================
# VPC CONFIGURATION
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # NAT Gateway configuration
  enable_nat_gateway = true
  single_nat_gateway = var.enable_single_nat_gateway

  # Internet Gateway
  create_igw = true

  # DNS configuration
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Manage default resources for better control
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${var.cluster_name}-default-nacl" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${var.cluster_name}-default-rt" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${var.cluster_name}-default-sg" }

  # Apply Kubernetes-specific tags to subnets
  public_subnet_tags  = merge(local.common_tags, local.public_subnet_tags)
  private_subnet_tags = merge(local.common_tags, local.private_subnet_tags)

  tags = local.common_tags
}

# =============================================================================
# EKS CLUSTER CONFIGURATION
# =============================================================================

module "retail_app_eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  # Basic cluster configuration
  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  # Cluster access configuration
  cluster_endpoint_public_access           = true
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = true

  # EKS Addons
  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    disk_size      = 20
    instance_types = ["t3.medium", "t3.large"]
  }

  eks_managed_node_groups = {
    # Core node group for critical cluster addons (On-Demand for stability)
    core = {
      min_size     = 1
      max_size     = 2
      desired_size = 1

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      
      labels = {
        role = "core"
      }
    }
    
    # Spot node group for application workloads (Cost optimization)
    app_spot = {
      min_size     = 1
      max_size     = 5
      desired_size = 2

      instance_types = ["t3.medium", "t3.large", "t3a.medium", "t3a.large"]
      capacity_type  = "SPOT"
      
      labels = {
        role = "application"
      }
      
      # Taint spot nodes so only tolerant workloads run on them if needed
      # (Optional: uncomment if you want strict scheduling)
      # taints = [{
      #   key    = "spotInstance"
      #   value  = "true"
      #   effect = "PREFER_NO_SCHEDULE"
      # }]
    }
  }

  # Network configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # KMS configuration to avoid conflicts
  create_kms_key = true
  kms_key_description = "EKS cluster ${local.cluster_name} encryption key"
  kms_key_deletion_window_in_days = 7
  
  # Cluster logging - Enable audit logs for production security compliance
  # (Removed expensive logs like api, authenticator unless strictly required)
  cluster_enabled_log_types = ["audit"]

  tags = local.common_tags
}
