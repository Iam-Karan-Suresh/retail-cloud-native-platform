# Spot Instance Graceful Migration — Production Architecture

## Architecture Overview

This infrastructure implements a **zero-downtime spot instance migration system** for EKS. When AWS reclaims a spot instance, workloads are automatically and gracefully migrated to healthy nodes — no human intervention, no dropped requests.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AWS EventBridge                              │
│                                                                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │ Spot Interruption │  │    Rebalance     │  │ Instance State   │  │
│  │   Warning (2min)  │  │  Recommendation  │  │    Change        │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘  │
│           │                     │                     │             │
│           └─────────────────────┼─────────────────────┘             │
│                                 │                                   │
│                                 ▼                                   │
│                    ┌────────────────────────┐                       │
│                    │     SQS Queue          │                       │
│                    │  (5-min retention,     │                       │
│                    │   long-polling)        │                       │
│                    └───────────┬────────────┘                       │
└───────────────────────────────┼─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         EKS Cluster                                 │
│                                                                     │
│  ┌─────────────────────────────────────────────────────┐           │
│  │  System Nodes (On-Demand, tainted)                   │           │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────────────┐ │           │
│  │  │  CoreDNS  │ │  Ingress │ │  Node Termination    │ │           │
│  │  │          │ │Controller│ │  Handler (NTH)        │ │           │
│  │  └──────────┘ └──────────┘ │  ┌────────────────┐  │ │           │
│  │                             │  │ Polls SQS      │  │ │           │
│  │  ┌──────────┐ ┌──────────┐ │  │ Cordons node   │  │ │           │
│  │  │ ArgoCD   │ │Prometheus│ │  │ Drains pods    │  │ │           │
│  │  │          │ │ Grafana  │ │  │ Completes hook │  │ │           │
│  │  └──────────┘ └──────────┘ │  └────────────────┘  │ │           │
│  │                             └──────────────────────┘ │           │
│  └─────────────────────────────────────────────────────┘           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────┐           │
│  │  Spot Worker Nodes (diverse instance types)          │           │
│  │                                                       │           │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐        │           │
│  │  │ Pod A  │ │ Pod B  │ │ Pod C  │ │ Pod D  │        │           │
│  │  │(AZ-a)  │ │(AZ-b)  │ │(AZ-c)  │ │(AZ-a)  │        │           │
│  │  └────────┘ └────────┘ └────────┘ └────────┘        │           │
│  │                                                       │           │
│  │  When spot reclaimed → NTH drains → pods reschedule  │           │
│  │  to remaining spot nodes or new ones from ASG         │           │
│  └─────────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

## The 2-Minute Window — What Happens in Sequence

```
T-120s  AWS sends Spot Interruption Warning → EventBridge → SQS
T-119s  NTH polls SQS, reads the event, identifies the node
T-118s  NTH cordons the node (kubectl cordon — no new pods scheduled)
T-117s  NTH starts drain (kubectl drain — evicts pods respecting PDBs)
T-115s  Pods receive SIGTERM via preStop hook, begin graceful shutdown
T-110s  ASG detects capacity gap, launches replacement spot instance
T-90s   New node joins cluster, passes readiness checks
T-80s   Evicted pods rescheduled on healthy nodes by kube-scheduler
T-60s   Old node fully drained, all pods relocated
T-30s   NTH completes ASG lifecycle hook ("I'm done, proceed")
T-0s    AWS reclaims the instance — your workloads already moved ✓
```

---

## File Structure

```
terraform/
├── main.tf                      # VPC + EKS cluster (system + spot node groups)
├── spot-termination.tf          # SQS queue + EventBridge rules pipeline
├── irsa.tf                      # IAM roles for NTH (IRSA — no static creds)
├── node-termination-handler.tf  # NTH Helm release (Queue Processor mode)
├── addons.tf                    # Cert-Manager, Ingress, Prometheus stack
├── argocd.tf                    # ArgoCD GitOps deployment
├── security.tf                  # Security group rules
├── locals.tf                    # Computed values & data sources
├── variables.tf                 # Input variables (incl. spot config)
├── outputs.tf                   # Cluster access & NTH info
├── versions.tf                  # Provider version constraints
└── README.md                    # This file

k8s/
├── spot-resilience/
│   └── deployment-template.yaml  # Reference deployment with PDB, topology spread
└── monitoring/
    └── spot-alerts.yaml          # Prometheus alerting rules for spot events
```

---

## What Changed & Why

### 1. Node Group Architecture — System vs Spot Split

| Aspect | Before | After | Why |
|--------|--------|-------|-----|
| Node Groups | Single `app_spot` group | `system` (On-Demand) + `spot_workers` (Spot) | Critical infra (DNS, Ingress, NTH) must NEVER run on spot instances |
| System Taint | None | `CriticalAddonsOnly=true:NoSchedule` | Prevents app workloads from consuming system node capacity |
| Instance Diversity | 4 types | 10 types (t3/t3a/m5/m5a) | More types = larger spot pool = lower interruption probability |
| IMDSv2 | Not configured | Enforced globally | Security best practice — blocks SSRF attacks against metadata endpoint |
| Labels | `role: core/application` | `role: system/spot-worker` + `node.kubernetes.io/lifecycle` | Standard labels for NTH, affinity rules, and monitoring queries |

**Cost Impact**: Spot instances are 60-80% cheaper than On-Demand. System nodes are small (t3.medium) and only run cluster infrastructure.

### 2. Spot Termination Pipeline (NEW)

| Component | File | Purpose |
|-----------|------|---------|
| **SQS Queue** | `spot-termination.tf` | Central inbox for all termination events. 5-min retention, long-polling to reduce API costs. |
| **EventBridge Rule: Spot Interruption** | `spot-termination.tf` | Catches the 2-minute warning from AWS |
| **EventBridge Rule: Rebalance** | `spot-termination.tf` | Catches rebalance recommendations (fires BEFORE interruption — extra lead time) |
| **EventBridge Rule: State Change** | `spot-termination.tf` | Catches instance stopping/terminating events |
| **EventBridge Rule: Scheduled Change** | `spot-termination.tf` | Catches AWS maintenance events |
| **ASG Lifecycle Hook** | `spot-termination.tf` | Pauses ASG termination for 300s, giving NTH time to drain before AWS kills the instance |
| **SQS Queue Policy** | `spot-termination.tf` | Scoped to only allow EventBridge to push — least privilege |

### 3. Node Termination Handler (NEW)

| Aspect | Details |
|--------|---------|
| **Mode** | Queue Processor (not DaemonSet) — recommended for production |
| **File** | `node-termination-handler.tf` |
| **Runs on** | System nodes only (nodeSelector: `role=system`) |
| **Tolerates** | `CriticalAddonsOnly` taint |
| **IRSA** | Dedicated IAM role via `irsa.tf` — no static credentials |
| **Metrics** | Exposes Prometheus metrics on port 9092 |
| **Resources** | 50m/64Mi request, 100m/128Mi limit — NTH is lightweight |

**Why Queue Processor instead of DaemonSet?**
- Doesn't require IMDSv1 access
- Single deployment vs one pod per node
- Scales better for large clusters
- Works with ALL event types (including ASG lifecycle)

### 4. IRSA — Zero Static Credentials (NEW)

| Aspect | Details |
|--------|---------|
| **File** | `irsa.tf` |
| **Pattern** | OIDC federation — K8s service account maps to IAM role |
| **Scope** | SQS: scoped to specific queue ARN. EC2/ASG: read-only describe |
| **Why** | No AWS access keys stored in cluster. Pods get temporary credentials via STS. If a pod is compromised, the blast radius is limited to SQS read + EC2 describe. |

### 5. Workload Resilience Patterns (NEW)

| Pattern | File | Why |
|---------|------|-----|
| **TopologySpreadConstraints** | `k8s/spot-resilience/deployment-template.yaml` | Spread pods across AZs AND nodes — one spot reclaim can't kill all replicas |
| **PodDisruptionBudget** | `k8s/spot-resilience/deployment-template.yaml` | NTH respects PDBs — guarantees 50% of pods stay running during drain |
| **Node Affinity (soft)** | `k8s/spot-resilience/deployment-template.yaml` | Prefer spot, fall back to on-demand — apps never get stuck if spot is unavailable |
| **Graceful Shutdown** | `k8s/spot-resilience/deployment-template.yaml` | preStop hook (5s) + terminationGracePeriodSeconds (90s) — fits within 2-min window |
| **Health Probes** | `k8s/spot-resilience/deployment-template.yaml` | Readiness probe removes pod from Service BEFORE shutdown begins |

### 6. Observability (NEW)

| Alert | Severity | Trigger |
|-------|----------|---------|
| `SpotNodeDraining` | Warning | A spot node is being drained — normal operational event |
| `HighSpotInterruptionRate` | Critical | Too many interruptions — add more instance type diversity |
| `NTHNotRunning` | Critical | NTH is down — P1 incident, spot reclaims won't be handled |
| `PodsPendingOnSpotNodes` | Warning | Pods stuck in Pending — possible capacity shortage |
| `PDBBlockingEviction` | Critical | PDB is blocking drain — workloads stuck on dying node |

### 7. Addons Hardened

| Addon | Change | Why |
|-------|--------|-----|
| **Ingress Controller** | Pinned to system nodes + CriticalAddonsOnly toleration + 2 replicas | Ingress on a spot node = potential traffic blackhole during reclaim |
| **Prometheus Stack** | Enabled by default | CloudWatch is 10x more expensive for the same metrics |

### 8. Variables & Validation

| Variable | Change | Why |
|----------|--------|-----|
| `environment` | Added validation (dev/staging/prod only) | Prevent typos that could create orphaned resources |
| `kubernetes_version` | Changed to `1.31` | `1.33` doesn't exist yet — would fail on apply |
| `spot_instance_types` | New variable | Configurable instance diversity without editing main.tf |
| `spot_min/max/desired_size` | New variables | Tunable spot capacity per environment |

---

## Cost Comparison

| Component | Without Spot | With This Architecture | Savings |
|-----------|-------------|----------------------|---------|
| 3x t3.medium On-Demand (24/7) | ~$90/mo | ~$27/mo (Spot) | **70%** |
| 5x t3.large On-Demand (24/7) | ~$300/mo | ~$75/mo (Spot) | **75%** |
| CloudWatch Container Insights | ~$50-200/mo | $0 (Prometheus) | **100%** |
| AWS CodePipeline/CD | ~$15-50/mo | $0 (ArgoCD) | **100%** |
| SQS (NTH events) | — | ~$0.01/mo | Negligible |
| EventBridge rules | — | Free tier | $0 |

**Estimated monthly savings for a 10-node cluster: $400-700/month**

---

## Quick Start

```bash
# 1. Initialize and apply infrastructure
cd terraform/
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan

# 2. Configure kubectl
$(terraform output -raw configure_kubectl)

# 3. Verify NTH is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-node-termination-handler

# 4. Verify node groups
kubectl get nodes -L role,node.kubernetes.io/lifecycle

# 5. Apply spot-resilient workload template
kubectl apply -f ../k8s/spot-resilience/deployment-template.yaml

# 6. Apply monitoring alerts
kubectl apply -f ../k8s/monitoring/spot-alerts.yaml

# 7. Get ArgoCD password
eval $(terraform output -raw argocd_initial_password_command)
```

## Verifying Spot Termination Handling

```bash
# Watch NTH logs in real-time
kubectl logs -f -n kube-system -l app.kubernetes.io/name=aws-node-termination-handler

# Check SQS queue depth (should be 0 when idle)
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw spot_termination_sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages

# Simulate a spot interruption (for testing)
# Use AWS FIS (Fault Injection Simulator) to trigger a spot interruption
# on a test node and watch NTH handle it gracefully.
```
