# =============================================================================
# SPOT INSTANCE TERMINATION HANDLING — EventBridge → SQS Pipeline
# =============================================================================
# This file creates the AWS-side plumbing that catches spot interruption
# signals and feeds them into SQS for the Node Termination Handler to consume.
#
# Flow:
#   AWS Spot Interruption Warning (2-min)  ──→ EventBridge ──→ SQS
#   EC2 Rebalance Recommendation           ──→ EventBridge ──→ SQS
#   ASG Lifecycle (scale-in, AZ rebalance)  ──→ EventBridge ──→ SQS
#   Scheduled Change (maintenance)          ──→ EventBridge ──→ SQS
#
# NTH pods running in the cluster poll this queue and take action.
# =============================================================================

# -----------------------------------------------------------------------------
# SQS QUEUE — Single queue for all termination-related events
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "node_termination" {
  name                       = "${local.cluster_name}-spot-termination"
  message_retention_seconds  = 300 # 5 min — events are time-critical
  receive_wait_time_seconds  = 20  # Long polling — reduces empty receives & cost
  visibility_timeout_seconds = 60  # Give NTH time to process before re-delivery

  tags = merge(local.common_tags, {
    Component = "spot-termination-handler"
  })
}

# SQS Queue Policy — allow EventBridge to push messages
resource "aws_sqs_queue_policy" "node_termination" {
  queue_url = aws_sqs_queue.node_termination.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeToSendMessages"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.node_termination.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [
            aws_cloudwatch_event_rule.spot_interruption.arn,
            aws_cloudwatch_event_rule.rebalance_recommendation.arn,
            aws_cloudwatch_event_rule.instance_state_change.arn,
            aws_cloudwatch_event_rule.scheduled_change.arn
          ]
        }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# EVENTBRIDGE RULES — Catch every signal that could mean "node going away"
# -----------------------------------------------------------------------------

# 1. Spot Interruption Warning (the critical 2-minute warning from AWS)
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${local.cluster_name}-spot-interruption"
  description = "Capture EC2 Spot Instance Interruption Warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "spot_interruption_to_sqs" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "SpotInterruptionToSQS"
  arn       = aws_sqs_queue.node_termination.arn
}

# 2. Rebalance Recommendation (AWS suggests moving before interruption)
#    This fires BEFORE the 2-min warning — gives you extra lead time
resource "aws_cloudwatch_event_rule" "rebalance_recommendation" {
  name        = "${local.cluster_name}-rebalance-recommendation"
  description = "Capture EC2 Instance Rebalance Recommendations"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "rebalance_to_sqs" {
  rule      = aws_cloudwatch_event_rule.rebalance_recommendation.name
  target_id = "RebalanceToSQS"
  arn       = aws_sqs_queue.node_termination.arn
}

# 3. Instance State Change (covers termination, stopping, etc.)
resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${local.cluster_name}-instance-state-change"
  description = "Capture EC2 Instance State-change Notifications"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "state_change_to_sqs" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "StateChangeToSQS"
  arn       = aws_sqs_queue.node_termination.arn
}

# 4. Scheduled Change (AWS maintenance events)
resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${local.cluster_name}-scheduled-change"
  description = "Capture AWS Health Scheduled Change events"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
    detail = {
      service           = ["EC2"]
      eventTypeCategory = ["scheduledChange"]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "scheduled_change_to_sqs" {
  rule      = aws_cloudwatch_event_rule.scheduled_change.name
  target_id = "ScheduledChangeToSQS"
  arn       = aws_sqs_queue.node_termination.arn
}

# -----------------------------------------------------------------------------
# ASG LIFECYCLE HOOKS — For graceful scale-in and AZ rebalancing
# -----------------------------------------------------------------------------
# When the ASG decides to terminate an instance (scale-in, AZ rebalance),
# this hook pauses the termination for up to 300s, giving NTH time to
# drain pods before AWS actually kills the instance.
# -----------------------------------------------------------------------------

# Lookup the ASG names created by the EKS module for spot worker nodes
data "aws_autoscaling_groups" "spot_workers" {
  filter {
    name   = "tag:eks:cluster-name"
    values = [local.cluster_name]
  }

  filter {
    name   = "tag:eks:nodegroup-name"
    values = ["spot_workers"]
  }

  depends_on = [module.retail_app_eks]
}

resource "aws_autoscaling_lifecycle_hook" "spot_termination" {
  count = length(data.aws_autoscaling_groups.spot_workers.names)

  name                   = "${local.cluster_name}-spot-termination-hook"
  autoscaling_group_name = data.aws_autoscaling_groups.spot_workers.names[count.index]
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = 300 # 5 minutes — NTH will CONTINUE after drain is done
  default_result         = "CONTINUE"

  depends_on = [module.retail_app_eks]
}
