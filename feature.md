Now let me build this comprehensive architecture solution with interactive diagrams.Click any node above to dive deeper into any component. Now here's the full step-by-step implementation guide from scratch:

---

## Step-by-step build guide

### Phase 1 — Foundation: EKS cluster with mixed node groups

**Step 1: Create the EKS cluster with Terraform**

Your cluster needs both on-demand (for system/critical pods) and spot node groups. The key is using `capacity_type = "SPOT"` with multiple instance types to reduce interruption probability.

```hcl
# terraform/eks.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "jfrog-workloads"
  cluster_version = "1.30"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  # System node group — on-demand, small, for kube-system
  eks_managed_node_groups = {
    system = {
      instance_types = ["m5.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels = { role = "system" }
      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }

    # Spot node group — diverse instance types = lower interruption rate
    spot-workers = {
      instance_types = [
        "m5.xlarge", "m5a.xlarge", "m5d.xlarge",
        "m4.xlarge", "m5n.xlarge", "m5zn.xlarge"
      ]
      capacity_type = "SPOT"
      min_size      = 2
      max_size      = 50
      desired_size  = 5
      labels = { role = "spot-worker" }

      # CRITICAL: enable instance metadata for NTH
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"  # IMDSv2
        http_put_response_hop_limit = 2
      }
    }
  }
}
```

**Step 2: Create the SQS queue for interruption events**

```hcl
# terraform/sqs.tf
resource "aws_sqs_queue" "node_termination" {
  name                      = "jfrog-spot-termination-queue"
  message_retention_seconds = 300   # 5 min — events are time-sensitive
  receive_wait_time_seconds = 20    # long polling saves cost

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = "arn:aws:sqs:*:*:jfrog-spot-termination-queue"
    }]
  })
}

# EventBridge rule: catch spot interruption warnings
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "spot-interruption-warning"
  description = "Capture EC2 Spot Instance Interruption Warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_to_sqs" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "SpotTerminationToSQS"
  arn       = aws_sqs_queue.node_termination.arn
}

# Also catch: Rebalance Recommendations + ASG lifecycle hooks
resource "aws_cloudwatch_event_rule" "rebalance" {
  name          = "spot-rebalance-recommendation"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "rebalance_to_sqs" {
  rule      = aws_cloudwatch_event_rule.rebalance.name
  target_id = "RebalanceToSQS"
  arn       = aws_sqs_queue.node_termination.arn
}
```

---

### Phase 2 — AWS Node Termination Handler (NTH)

**Step 3: Create the IRSA role for NTH**

```hcl
# terraform/irsa.tf
module "nth_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "aws-node-termination-handler"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node-termination-handler"]
    }
  }

  role_policy_arns = {
    nth = aws_iam_policy.nth.arn
  }
}

resource "aws_iam_policy" "nth" {
  name = "NTHPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "autoscaling:CompleteLifecycleAction",
          "autoscaling:DescribeAutoScalingInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}
```

**Step 4: Install NTH via Helm**

```yaml
# helm/nth-values.yaml
enableSqsTerminationDraining: true
enableSpotInterruptionDraining: true
enableRebalanceMonitoring: true
enableRebalanceDraining: true
enableScheduledEventDraining: true

queueURL: "https://sqs.us-east-1.amazonaws.com/YOUR_ACCOUNT/jfrog-spot-termination-queue"

nodeSelector:
  role: system    # run NTH itself on on-demand nodes

tolerations:
  - operator: "Exists"  # must tolerate ALL taints to run on spot nodes too

# CRITICAL: NTH must run as DaemonSet on worker nodes
daemonsetNodeSelector:
  role: spot-worker

serviceAccount:
  name: aws-node-termination-handler
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT:role/aws-node-termination-handler"

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9092"
```

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-node-termination-handler \
  eks/aws-node-termination-handler \
  --namespace kube-system \
  --values helm/nth-values.yaml
```

---

### Phase 3 — Karpenter (recommended over Cluster Autoscaler for spot)

**Step 5: Install Karpenter and define a NodePool**

Karpenter reacts faster than Cluster Autoscaler — it watches for pending pods and provisions a new node in ~30 seconds vs 2–3 minutes.

```yaml
# karpenter/nodepool.yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: spot-workers
spec:
  template:
    metadata:
      labels:
        role: spot-worker
    spec:
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: spot-nodeclass

      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["m5", "m5a", "m5d", "m4", "m5n"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["xlarge", "2xlarge"]

  limits:
    cpu: 500
    memory: 2000Gi

  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s

---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: spot-nodeclass
spec:
  amiFamily: AL2
  role: "KarpenterNodeRole-jfrog-workloads"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "jfrog-workloads"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "jfrog-workloads"

  # Fast node startup — pre-baked AMI or bootstrap script
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh jfrog-workloads \
      --kubelet-extra-args '--max-pods=110'
```

---

### Phase 4 — Workload resilience (the other half of the solution)

Your workloads also need to be spot-aware. A perfectly configured NTH fails if apps don't handle SIGTERM gracefully.

**Step 6: Configure PodDisruptionBudgets**

```yaml
# k8s/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-service-pdb
spec:
  minAvailable: "50%"   # always keep at least 50% of pods running
  selector:
    matchLabels:
      app: api-service
```

**Step 7: Set up topology spread across AZs**

```yaml
# k8s/deployment-spot-ready.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
spec:
  replicas: 6
  template:
    metadata:
      labels:
        app: api-service
    spec:
      # Spread across AZs so one spot interruption can't take out all pods
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: api-service

      # Prefer spot, fall back to on-demand
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: karpenter.sh/capacity-type
                    operator: In
                    values: ["spot"]

      containers:
        - name: api-service
          image: your-registry/api-service:latest

          # CRITICAL: graceful shutdown must complete within this window
          # NTH gives you 2 minutes — budget for 90s shutdown
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]  # drain in-flight requests

          # Signal handling — your app MUST handle SIGTERM
          terminationGracePeriodSeconds: 90

          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
```

**Step 8: Application-level SIGTERM handling** (example in Node.js)

```javascript
// Your app must close connections gracefully on SIGTERM
process.on('SIGTERM', async () => {
  console.log('SIGTERM received — starting graceful shutdown');
  
  // Stop accepting new requests
  server.close(async () => {
    // Drain in-flight work
    await queue.flush();
    await db.disconnect();
    console.log('Shutdown complete');
    process.exit(0);
  });

  // Force exit if graceful shutdown takes too long
  setTimeout(() => process.exit(1), 85_000);
});
```

---

### Phase 5 — Observability

**Step 9: CloudWatch + Prometheus alerts**

```yaml
# monitoring/prometheus-rules.yaml
groups:
  - name: spot-interruption
    rules:
      - alert: SpotNodeDraining
        expr: aws_node_termination_handler_actions_total{action="cordon"} > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "Spot node is being drained — {{ $labels.node }}"

      - alert: HighSpotInterruptionRate
        expr: rate(aws_node_termination_handler_actions_total[10m]) > 0.5
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High spot interruption rate — check instance type diversity"
```

---

### The 2-minute window — what happens in sequence

```
T-120s  AWS sends Spot Interruption Warning → EventBridge → SQS
T-119s  NTH polls SQS, reads the event
T-118s  NTH cordons the node (no new pods scheduled)
T-117s  NTH drains: evicts pods respecting PDBs
T-115s  Pods receive SIGTERM, begin graceful shutdown
T-110s  Karpenter sees pending pods, begins provisioning new spot node
T-90s   New node joins cluster, Ready
T-80s   Pods rescheduled on new node
T-60s   Old node fully drained
T-0s    AWS reclaims the instance (your workloads already moved)
```

---

### Cost impact summary

Running stateless workloads on spot vs on-demand typically saves **60–80%** on compute. With NTH + Karpenter + diverse instance pools, interruption-driven downtime drops to near zero because the 2-minute window is more than enough to migrate pods when the system is configured correctly.

The full Terraform, Helm, and Kubernetes manifests above give you a production-grade foundation. The nodes getting reclaimed become a non-event.