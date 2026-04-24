# =============================================================================
# AWS NODE TERMINATION HANDLER (NTH) — Helm Deployment
# =============================================================================
# NTH is the brain of the spot migration system. It:
#   1. Polls the SQS queue for interruption/rebalance/lifecycle events
#   2. Cordons the affected node (no new pods scheduled)
#   3. Drains the node (evicts pods, respecting PDBs)
#   4. Completes the ASG lifecycle hook (tells AWS "I'm done, proceed")
#
# Deployed in QUEUE PROCESSOR mode (not DaemonSet) — single deployment
# that watches SQS. This is the recommended mode for production because
# it doesn't require IMDSv1 access and scales better.
# =============================================================================

resource "helm_release" "node_termination_handler" {
  name       = "aws-node-termination-handler"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-node-termination-handler"
  namespace  = "kube-system"
  version    = "0.25.1"

  # ---------------------------------------------------------------------------
  # QUEUE PROCESSOR MODE — reads events from SQS
  # ---------------------------------------------------------------------------
  set {
    name  = "enableSqsTerminationDraining"
    value = "true"
  }

  set {
    name  = "queueURL"
    value = aws_sqs_queue.node_termination.url
  }

  # ---------------------------------------------------------------------------
  # SPOT INTERRUPTION DRAINING — handle the 2-minute warning
  # ---------------------------------------------------------------------------
  set {
    name  = "enableSpotInterruptionDraining"
    value = "true"
  }

  # ---------------------------------------------------------------------------
  # REBALANCE MONITORING — proactive rebalance before interruption
  # ---------------------------------------------------------------------------
  set {
    name  = "enableRebalanceMonitoring"
    value = "true"
  }

  set {
    name  = "enableRebalanceDraining"
    value = "true"
  }

  # ---------------------------------------------------------------------------
  # SCHEDULED EVENT DRAINING — handle AWS maintenance events
  # ---------------------------------------------------------------------------
  set {
    name  = "enableScheduledEventDraining"
    value = "true"
  }

  # ---------------------------------------------------------------------------
  # IRSA — service account mapped to the IAM role we created
  # ---------------------------------------------------------------------------
  set {
    name  = "serviceAccount.name"
    value = "aws-node-termination-handler"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.nth_irsa.iam_role_arn
  }

  # ---------------------------------------------------------------------------
  # SCHEDULING — NTH itself MUST run on On-Demand system nodes
  # If NTH runs on a spot node, it could get killed before it can drain others
  # ---------------------------------------------------------------------------
  set {
    name  = "nodeSelector.role"
    value = "system"
  }

  # System nodes have a CriticalAddonsOnly taint — NTH must tolerate it
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
  # PROMETHEUS METRICS — expose NTH metrics for alerting
  # ---------------------------------------------------------------------------
  set {
    name  = "podAnnotations.prometheus\\.io/scrape"
    value = "true"
  }

  set {
    name  = "podAnnotations.prometheus\\.io/port"
    value = "9092"
  }

  # ---------------------------------------------------------------------------
  # RESOURCE LIMITS — NTH is lightweight, don't over-provision
  # ---------------------------------------------------------------------------
  set {
    name  = "resources.requests.cpu"
    value = "50m"
  }

  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "100m"
  }

  set {
    name  = "resources.limits.memory"
    value = "128Mi"
  }

  depends_on = [
    module.retail_app_eks,
    module.nth_irsa,
    aws_sqs_queue.node_termination
  ]
}
