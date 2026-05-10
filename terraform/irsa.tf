# =============================================================================
# IAM ROLES FOR SERVICE ACCOUNTS (IRSA)
# =============================================================================
# IRSA lets Kubernetes pods assume AWS IAM roles without storing credentials.
# Each service gets exactly the permissions it needs — zero more.
# =============================================================================

# -----------------------------------------------------------------------------
# NTH IRSA — REMOVED (replaced by Karpenter)
# -----------------------------------------------------------------------------
# The NTH IRSA role (module.nth_irsa) and its IAM policy (aws_iam_policy.nth)
# have been removed. Karpenter handles spot interruption natively and has
# its own IRSA role defined in karpenter.tf (module.karpenter_irsa).
#
# Removed resources:
#   - module "nth_irsa"
#   - aws_iam_policy "nth"
# -----------------------------------------------------------------------------
