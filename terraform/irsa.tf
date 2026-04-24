# =============================================================================
# IAM ROLES FOR SERVICE ACCOUNTS (IRSA)
# =============================================================================
# IRSA lets Kubernetes pods assume AWS IAM roles without storing credentials.
# Each service gets exactly the permissions it needs — zero more.
# =============================================================================

# -----------------------------------------------------------------------------
# NODE TERMINATION HANDLER (NTH) — IRSA ROLE
# -----------------------------------------------------------------------------
# NTH needs to: read SQS messages, describe EC2 instances,
# and complete ASG lifecycle actions after draining pods.
# -----------------------------------------------------------------------------

module "nth_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.cluster_name}-nth"

  oidc_providers = {
    main = {
      provider_arn               = module.retail_app_eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node-termination-handler"]
    }
  }

  role_policy_arns = {
    nth = aws_iam_policy.nth.arn
  }

  tags = local.common_tags
}

resource "aws_iam_policy" "nth" {
  name        = "${local.cluster_name}-NTHPolicy"
  description = "Policy for AWS Node Termination Handler to read SQS, describe instances, and complete ASG lifecycle hooks"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.node_termination.arn
      },
      {
        Sid    = "ASGLifecycle"
        Effect = "Allow"
        Action = [
          "autoscaling:CompleteLifecycleAction",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}
