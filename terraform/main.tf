# =============================================================================
# MAIN INFRASTRUCTURE RESOURCES
# =============================================================================
# Architecture: Production-grade EKS with Spot Instance workload migration
# Cost Strategy: On-Demand for system stability, Spot for stateless apps
# =============================================================================

# =============================================================================
# VPC CONFIGURATION
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

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
  version = "~> 21.20"

  # Basic cluster configuration
  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  # Cluster access configuration
  cluster_endpoint_public_access           = true
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = true

  # ---------------------------------------------------------------------------
  # EKS MANAGED ADDONS
  # ---------------------------------------------------------------------------
  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  # ---------------------------------------------------------------------------
  # NODE GROUP DEFAULTS
  # ---------------------------------------------------------------------------
  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    disk_size      = 20
    instance_types = ["t3.medium", "t3.large"]

    # IMDSv2 enforced — required for NTH and security best practice
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 2
    }
  }

  # ---------------------------------------------------------------------------
  # NODE GROUPS — SPLIT BY ROLE
  # ---------------------------------------------------------------------------
  # Strategy:
  #   system  → On-Demand, tainted for critical addons only
  #   app_spot → Spot, diverse instance types to minimize interruption rate
  # ---------------------------------------------------------------------------
  eks_managed_node_groups = {

    # =========================================================================
    # SYSTEM NODE GROUP — On-Demand, dedicated to cluster addons
    # =========================================================================
    # Runs: CoreDNS, Ingress Controller, NTH, Prometheus, ArgoCD
    # Why On-Demand: These must NEVER be interrupted. A spot reclaim here
    #   could take down DNS resolution or monitoring for the entire cluster.
    # Taint: CriticalAddonsOnly — only pods with the matching toleration
    #   will be scheduled here. Prevents app workloads from landing here.
    # =========================================================================
    system = {
      min_size     = 2
      max_size     = 4
      desired_size = 2

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      labels = {
        role                           = "system"
        "node.kubernetes.io/lifecycle" = "on-demand"
      }

      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }

    # =========================================================================
    # SPOT WORKER NODE GROUP — For all stateless application workloads
    # =========================================================================
    # CRITICAL DESIGN DECISIONS:
    #   1. Multiple instance types (t3/t3a/m5/m5a) — AWS picks from a wider
    #      pool, drastically reducing interruption probability.
    #   2. capacity_type = SPOT — 60-80% cheaper than On-Demand.
    #   3. Labels tell NTH and PDBs which nodes are spot-backed.
    #   4. No taints by default — apps schedule here naturally. Only system
    #      pods are tainted away (on the system group above).
    # =========================================================================
    spot_workers = {
      min_size     = 2
      max_size     = 20
      desired_size = 3

      instance_types = [
        "t3.medium", "t3.large", "t3.xlarge",
        "t3a.medium", "t3a.large", "t3a.xlarge",
        "m5.large", "m5.xlarge",
        "m5a.large", "m5a.xlarge"
      ]
      capacity_type = "SPOT"

      labels = {
        role                           = "spot-worker"
        "node.kubernetes.io/lifecycle" = "spot"
      }
    }
  }

  # Network configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # KMS — Envelope encryption for Kubernetes Secrets at rest
  create_kms_key                  = true
  kms_key_description             = "EKS cluster ${local.cluster_name} encryption key"
  kms_key_deletion_window_in_days = 7

  # Cluster logging — audit only (api/authenticator logs are expensive)
  cluster_enabled_log_types = ["audit"]

  tags = local.common_tags
}
