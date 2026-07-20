# =============================================================================
# ARGOCD GITOPS DEPLOYMENT 
# =============================================================================

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace
  }

  depends_on = [module.retail_app_eks]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  # Basic high availability and resource limits for production
  values = [
    <<-EOT
    server:
      replicas: 2
      resources:
        limits:
          cpu: 500m
          memory: 512Mi
        requests:
          cpu: 100m
          memory: 256Mi
    repoServer:
      replicas: 2
    applicationSet:
      replicas: 2
    EOT
  ]

  depends_on = [kubernetes_namespace_v1.argocd]
}