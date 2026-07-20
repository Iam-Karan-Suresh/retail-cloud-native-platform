# =============================================================================
# KARPENTER — Cluster Autoprovisioner (replaces ASG-based spot workers)
# =============================================================================
# Karpenter directly provisions EC2 instances (no ASGs) based on pending pod
# requirements. Benefits over Cluster Autoscaler + ASG:
#   1. Instance-level flexibility — picks optimal instance type per workload
#   2. Faster scaling — no ASG lag, direct EC2 RunInstances calls
#   3. Consolidation — actively bin-packs and replaces underutilised nodes
#   4. Native spot handling — built-in interruption awareness via SQS
#
# This file creates:
#   - IRSA role for the Karpenter controller pod
#   - Least-privilege IAM policy
#   - Helm release pointing at the EXISTING SQS queue
# =============================================================================

# =============================================================================
# DATA SOURCES
# =============================================================================

# Lookup the node instance role created by the EKS module for spot workers.
# Karpenter needs iam:PassRole on this role to launch nodes that join the cluster.
data "aws_iam_role" "eks_node_role" {
  name = module.retail_app_eks.eks_managed_node_groups["spot_workers"].iam_role_name
}

# Lookup the instance profile so Karpenter's EC2NodeClass can reference it.
data "aws_iam_instance_profile" "eks_node" {
  name = module.retail_app_eks.eks_managed_node_groups["spot_workers"].iam_role_name
}

# =============================================================================
# KARPENTER IRSA — IAM Role for the controller pod
# =============================================================================

module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.40"

  role_name = "${local.cluster_name}-karpenter-controller"

  oidc_providers = {
    main = {
      provider_arn               = module.retail_app_eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:karpenter"]
    }
  }

  role_policy_arns = {
    karpenter = aws_iam_policy.karpenter_controller.arn
  }

  tags = local.common_tags
}

# =============================================================================
# KARPENTER IAM POLICY — Least-privilege permissions
# =============================================================================
# Follows the principle of least privilege:
#   - ec2:RunInstances scoped to the account (AWS requires * for some Describe)
#   - ec2:TerminateInstances scoped to instances tagged by Karpenter
#   - sqs: scoped to the EXISTING termination queue
#   - iam:PassRole scoped to the node instance role only
#   - ec2:CreateTags scoped to instances/volumes/network-interfaces at launch
#   - ec2:CreateFleet for Karpenter's fleet-based provisioning
#   - ssm:GetParameter for AMI resolution via SSM alias
#   - pricing:GetProducts for instance type pricing data
# =============================================================================

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${local.cluster_name}-KarpenterControllerPolicy"
  description = "IAM policy for Karpenter controller to provision and manage EC2 instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # -----------------------------------------------------------------
      # EC2: Launch instances (RunInstances needs broad resource scope)
      # -----------------------------------------------------------------
      {
        Sid    = "EC2RunInstances"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet"
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:launch-template/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:security-group/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:subnet/*",
          "arn:aws:ec2:${var.aws_region}::image/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:volume/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:fleet/*"
        ]
      },
      # -----------------------------------------------------------------
      # EC2: Terminate instances managed by Karpenter only
      # -----------------------------------------------------------------
      {
        Sid    = "EC2TerminateInstances"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances"
        ]
        Resource = "arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      # -----------------------------------------------------------------
      # EC2: Describe actions (AWS requires Resource = * for these)
      # -----------------------------------------------------------------
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeImages",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeInstanceTypeOfferings"
        ]
        Resource = "*"
      },
      # -----------------------------------------------------------------
      # EC2: Tag instances at creation time
      # -----------------------------------------------------------------
      {
        Sid    = "EC2CreateTags"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:volume/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:fleet/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:launch-template/*"
        ]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = [
              "RunInstances",
              "CreateFleet",
              "CreateLaunchTemplate"
            ]
          }
        }
      },
      # -----------------------------------------------------------------
      # EC2: Manage launch templates created by Karpenter
      # -----------------------------------------------------------------
      {
        Sid    = "EC2LaunchTemplates"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = "arn:aws:ec2:${var.aws_region}:${local.account_id}:launch-template/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/karpenter.sh/cluster" = local.cluster_name
          }
        }
      },
      # -----------------------------------------------------------------
      # SQS: Read from the EXISTING termination queue
      # -----------------------------------------------------------------
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.node_termination.arn
      },
      # -----------------------------------------------------------------
      # IAM: PassRole scoped to the node instance role ONLY
      # -----------------------------------------------------------------
      {
        Sid    = "IAMPassRole"
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = data.aws_iam_role.eks_node_role.arn
      },
      # -----------------------------------------------------------------
      # SSM: Read AMI parameter for AL2 image discovery
      # -----------------------------------------------------------------
      {
        Sid    = "SSMGetParameter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}::parameter/aws/service/eks/optimized-ami/*"
      },
      # -----------------------------------------------------------------
      # Pricing: Instance type cost data for spot/OD decisions
      # -----------------------------------------------------------------
      {
        Sid    = "PricingAccess"
        Effect = "Allow"
        Action = [
          "pricing:GetProducts"
        ]
        # pricing API only exists in us-east-1 and ap-south-1 — Resource must be *
        Resource = "*"
      },
      # -----------------------------------------------------------------
      # EKS: Describe cluster for endpoint/CA discovery
      # -----------------------------------------------------------------
      {
        Sid    = "EKSDescribeCluster"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = module.retail_app_eks.cluster_arn
      },
      # -----------------------------------------------------------------
      # IAM: Get/Create instance profile for Karpenter-managed nodes
      # -----------------------------------------------------------------
      {
        Sid    = "IAMInstanceProfile"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile"
        ]
        Resource = "arn:aws:iam::${local.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/karpenter.sh/cluster" = local.cluster_name
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# =============================================================================
# KARPENTER — Access Entry for nodes to join the cluster
# =============================================================================
# Karpenter-launched nodes need permission to join the EKS cluster.
# This creates an access entry so Karpenter-provisioned instances
# authenticate with the cluster via their instance role.
# =============================================================================

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = module.retail_app_eks.cluster_name
  principal_arn = data.aws_iam_role.eks_node_role.arn
  type          = "EC2_LINUX"

  tags = local.common_tags
}

# =============================================================================
# KARPENTER HELM RELEASE
# =============================================================================
# Deployed to kube-system namespace. Uses the EXISTING SQS queue for
# spot interruption events — we do NOT create a new queue.
#
# The controller runs on SYSTEM nodes (On-Demand) to ensure it is
# never interrupted by the very spot reclaims it manages.
# =============================================================================

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.12.0"
  namespace  = "kube-system"

  # ---------------------------------------------------------------------------
  # Cluster identity — tells Karpenter which EKS cluster to manage
  # ---------------------------------------------------------------------------
  set {
    name  = "settings.clusterName"
    value = module.retail_app_eks.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = module.retail_app_eks.cluster_endpoint
  }

  # ---------------------------------------------------------------------------
  # IRSA — service account mapped to the IAM role above
  # ---------------------------------------------------------------------------
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter_irsa.iam_role_arn
  }

  # ---------------------------------------------------------------------------
  # SQS QUEUE — reuse existing EventBridge → SQS pipeline
  # Karpenter natively consumes spot interruption events from SQS
  # ---------------------------------------------------------------------------
  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.node_termination.name
  }

  # ---------------------------------------------------------------------------
  # SCHEDULING — Karpenter controller MUST run on On-Demand system nodes
  # If Karpenter itself is on a spot node, it could be killed and the
  # cluster loses its ability to provision replacement capacity.
  # ---------------------------------------------------------------------------
  set {
    name  = "nodeSelector.role"
    value = "system"
  }

  # System nodes have a CriticalAddonsOnly taint — Karpenter must tolerate it
  set {
    name  = "tolerations[0].key"
    value = "CriticalAddonsOnly"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  # ---------------------------------------------------------------------------
  # REPLICAS — run 2 for HA (leader election ensures only one is active)
  # ---------------------------------------------------------------------------
  set {
    name  = "replicas"
    value = "2"
  }

  # ---------------------------------------------------------------------------
  # RESOURCE LIMITS — Karpenter is lightweight but needs room for caching
  # ---------------------------------------------------------------------------
  set {
    name  = "resources.requests.cpu"
    value = "200m"
  }

  set {
    name  = "resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "1"
  }

  set {
    name  = "resources.limits.memory"
    value = "512Mi"
  }

  # ---------------------------------------------------------------------------
  # PROMETHEUS METRICS — expose Karpenter metrics for cost/performance dashboards
  # ---------------------------------------------------------------------------
  set {
    name  = "controller.metrics.port"
    value = "8080"
  }

  depends_on = [
    module.retail_app_eks,
    module.karpenter_irsa,
    aws_sqs_queue.node_termination,
    aws_eks_access_entry.karpenter_node
  ]
}
