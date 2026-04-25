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
  # NGINX INGRESS CONTROLLER — DISABLED (replaced by Traefik Gateway API)
  # =============================================================================
  # Previously used nginx ingress. Now using Traefik with Gateway API.
  # See helm_release.traefik below for the replacement.
  # =============================================================================
  enable_ingress_nginx = false

  # =============================================================================
  # OPEN-SOURCE MONITORING STACK (Cost effective compared to CloudWatch)
  # Prometheus + Grafana — runs on system nodes for stability
  # =============================================================================
  enable_kube_prometheus_stack = var.enable_monitoring
  kube_prometheus_stack = {
    most_recent = true
    namespace   = "monitoring"
  }

  tags = local.tags

  depends_on = [module.retail_app_eks]
}

# =============================================================================
# TRAEFIK — Gateway API Implementation (replaces NGINX Ingress)
# =============================================================================
# Traefik is deployed as the Gateway API provider. Benefits over NGINX:
#   1. Native Gateway API support (gateway.networking.k8s.io/v1)
#   2. Auto-discovers Gateway/HTTPRoute resources
#   3. Built-in middleware CRDs for rate limiting, body size, redirects
#   4. Superior observability with built-in dashboard
#   5. No annotation sprawl — configuration is declarative CRDs
#
# Pinned to SYSTEM nodes (On-Demand) — gateway must never be interrupted
# =============================================================================
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "28.0.0"
  namespace        = "traefik-system"
  create_namespace = true

  # Enable Gateway API provider (replaces Ingress controller mode)
  set {
    name  = "providers.kubernetesGateway.enabled"
    value = "true"
  }

  # Disable legacy Ingress provider
  set {
    name  = "providers.kubernetesIngress.enabled"
    value = "false"
  }

  # Service type — LoadBalancer for external traffic
  set {
    name  = "service.type"
    value = "LoadBalancer"
  }

  # External traffic policy — preserve client source IP
  set {
    name  = "service.spec.externalTrafficPolicy"
    value = "Local"
  }

  # Pin Traefik to system (on-demand) nodes — must not be interrupted
  set {
    name  = "nodeSelector.role"
    value = "system"
  }

  # Tolerate CriticalAddonsOnly taint on system nodes
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

  # Resource requests/limits
  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "300m"
  }
  set {
    name  = "resources.limits.memory"
    value = "256Mi"
  }

  # HA: run 2 replicas
  set {
    name  = "deployment.replicas"
    value = "2"
  }

  # AWS NLB annotations
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
    value = "instance"
  }

  depends_on = [module.retail_app_eks]
}

# =============================================================================
# KEDA — Kubernetes Event-Driven Autoscaling (replaces HPA)
# =============================================================================
# KEDA provides event-driven autoscaling for the Orders service based on
# RabbitMQ queue depth. Benefits over HPA:
#   1. Scales on LEADING indicators (queue depth) not LAGGING (CPU)
#   2. Can scale to zero → cost savings
#   3. Native RabbitMQ scaler (no custom metrics adapter needed)
#   4. Configurable cooldown periods prevent thrashing
#
# Pinned to SYSTEM nodes for stability
# =============================================================================
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.14.0"
  namespace        = "keda"
  create_namespace = true

  # Pin KEDA operator to system nodes
  set {
    name  = "nodeSelector.role"
    value = "system"
  }
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

  # Resource limits for KEDA operator
  set {
    name  = "resources.operator.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.operator.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "resources.operator.limits.cpu"
    value = "200m"
  }
  set {
    name  = "resources.operator.limits.memory"
    value = "256Mi"
  }

  depends_on = [module.retail_app_eks]
}
