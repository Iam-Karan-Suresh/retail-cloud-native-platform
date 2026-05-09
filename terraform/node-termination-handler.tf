# =============================================================================
# AWS NODE TERMINATION HANDLER (NTH) — REMOVED
# =============================================================================
# NTH has been replaced by Karpenter, which natively handles spot interruption
# events via the same SQS queue (aws_sqs_queue.node_termination).
#
# Karpenter advantages over NTH:
#   - No separate controller needed — interruption handling is built-in
#   - Proactively replaces nodes BEFORE interruption (not just drain)
#   - Consolidation replaces underutilised nodes automatically
#
# The NTH Helm release, IRSA role, and IAM policy have been removed.
# See karpenter.tf for the replacement.
#
# Removed resources:
#   - helm_release.node_termination_handler
#   - module.nth_irsa            (was in irsa.tf)
#   - aws_iam_policy.nth         (was in irsa.tf)
# =============================================================================
