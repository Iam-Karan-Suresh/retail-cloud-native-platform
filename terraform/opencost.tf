# =============================================================================
# OPENCOST - KUBERNETES COST MONITORING
# =============================================================================
# OpenCost provides real-time cost monitoring and resource usage for Kubernetes.
# It integrates with the existing Prometheus stack deployed in the cluster.
# =============================================================================

resource "helm_release" "opencost" {
  count            = var.enable_monitoring ? 1 : 0
  name             = "opencost"
  repository       = "https://opencost.github.io/opencost-helm-chart"
  chart            = "opencost"
  namespace        = "opencost"
  create_namespace = true
  version          = "1.33.0"

  set {
    name  = "opencost.exporter.defaultClusterId"
    value = var.cluster_name
  }

  # Disable internal Prometheus, use the existing kube-prometheus-stack
  set {
    name  = "opencost.prometheus.internal.enabled"
    value = "false"
  }

  set {
    name  = "opencost.prometheus.external.enabled"
    value = "true"
  }

  set {
    name  = "opencost.prometheus.external.url"
    value = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
  }

  # Pin to system nodes to ensure stability and avoid spot interruptions
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

  depends_on = [module.eks_addons]
}
