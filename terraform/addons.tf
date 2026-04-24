# =============================================================================
# EKS ADD-ONS AND EXTENSIONS
# =============================================================================

module "eks_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  # Cluster information
  cluster_name      = module.retail_app_eks.cluster_name
  cluster_endpoint  = module.retail_app_eks.cluster_endpoint
  cluster_version   = module.retail_app_eks.cluster_version
  oidc_provider_arn = module.retail_app_eks.oidc_provider_arn

  # =============================================================================
  # CERT-MANAGER - SSL Certificate Management
  # =============================================================================
  enable_cert_manager = true
  cert_manager = {
    most_recent = true
    namespace   = "cert-manager"
  }

  # =============================================================================
  # NGINX INGRESS CONTROLLER — Load Balancing and Routing
  # Pinned to SYSTEM nodes (On-Demand) — ingress must never be interrupted
  # =============================================================================
  enable_ingress_nginx = true
  ingress_nginx = {
    most_recent = true
    namespace   = "ingress-nginx"

    set = [
      {
        name  = "controller.service.type"
        value = "LoadBalancer"
      },
      {
        name  = "controller.service.externalTrafficPolicy"
        value = "Local"
      },
      # Pin ingress controller to system (on-demand) nodes
      {
        name  = "controller.nodeSelector.role"
        value = "system"
      },
      # Tolerate the CriticalAddonsOnly taint on system nodes
      {
        name  = "controller.tolerations[0].key"
        value = "CriticalAddonsOnly"
      },
      {
        name  = "controller.tolerations[0].operator"
        value = "Exists"
      },
      {
        name  = "controller.tolerations[0].effect"
        value = "NoSchedule"
      },
      {
        name  = "controller.resources.requests.cpu"
        value = "100m"
      },
      {
        name  = "controller.resources.requests.memory"
        value = "128Mi"
      },
      {
        name  = "controller.resources.limits.cpu"
        value = "200m"
      },
      {
        name  = "controller.resources.limits.memory"
        value = "256Mi"
      },
      # HA: run 2 replicas of ingress controller
      {
        name  = "controller.replicaCount"
        value = "2"
      }
    ]

    # AWS Load Balancer specific annotations
    set_sensitive = [
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
        value = "internet-facing"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
        value = "nlb"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
        value = "instance"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-health-check-path"
        value = "/healthz"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-health-check-port"
        value = "10254"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-health-check-protocol"
        value = "HTTP"
      }
    ]
  }

  # =============================================================================
  # OPEN-SOURCE MONITORING STACK (Cost effective compared to CloudWatch)
  # Prometheus + Grafana — runs on system nodes for stability
  # =============================================================================
  enable_kube_prometheus_stack = var.enable_monitoring
  kube_prometheus_stack = {
    most_recent = true
    namespace   = "monitoring"
  }

  depends_on = [module.retail_app_eks]
}
