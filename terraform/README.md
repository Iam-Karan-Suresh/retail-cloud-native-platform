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
│           └─────────────────────┼─────────────────────┘             │
│                                 ▼                                   │
│                    ┌────────────────────────┐                       │
│                    │    SQS Queue           │                       │
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
│  │  ON-DEMAND SYSTEM NODES (tainted: CriticalAddonsOnly)│           │
│  │                                                       │           │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────────────┐ │           │
│  │  │  CoreDNS  │ │  Ingress │ │  Node Termination    │ │           │
│  │  │          │ │Controller│ │  Handler (NTH)        │ │           │
│  │  └──────────┘ └──────────┘ └──────────────────────┘ │           │
│  │                                                       │           │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐ │           │
│  │  │ ArgoCD   │ │Prometheus│ │PostgreSQL│ │ MySQL  │ │           │
│  │  │          │ │ Grafana  │ │(orders)  │ │(catlog)│ │           │
│  │  └──────────┘ └──────────┘ └──────────┘ └────────┘ │           │
│  │                                                       │           │
│  │  ┌──────────┐ ┌──────────┐                           │           │
│  │  │ RabbitMQ │ │  Redis   │                           │           │
│  │  │(orders)  │ │(checkout)│                           │           │
│  │  └──────────┘ └──────────┘                           │           │
│  └─────────────────────────────────────────────────────┘           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────┐           │
│  │  SPOT WORKER NODES (t3/t3a/m5/m5a — 10 types)       │           │
│  │                                                       │           │
│  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐               │           │
│  │  │ UI   │ │ UI   │ │ UI   │ │ UI   │  4 replicas   │           │
│  │  │(AZ-a)│ │(AZ-b)│ │(AZ-c)│ │(AZ-a)│  PDB: min 3  │           │
│  │  └──────┘ └──────┘ └──────┘ └──────┘               │           │
│  │                                                       │           │
│  │  ┌──────┐ ┌──────┐ ┌──────┐     ┌──────┐ ┌──────┐  │           │
│  │  │ Cart │ │ Cart │ │ Cart │     │Catlog│ │Catlog│  │           │
│  │  │(AZ-a)│ │(AZ-b)│ │(AZ-c)│     │(AZ-a)│ │(AZ-b)│  │           │
│  │  └──────┘ └──────┘ └──────┘     └──────┘ └──────┘  │           │
│  │                                                       │           │
│  │  ┌──────┐ ┌──────┐ ┌──────┐     ┌──────┐ ┌──────┐  │           │
│  │  │Chkout│ │Chkout│ │Chkout│     │Orders│ │Orders│  │           │
│  │  │(AZ-a)│ │(AZ-b)│ │(AZ-c)│     │(AZ-a)│ │(AZ-b)│  │           │
│  │  └──────┘ └──────┘ └──────┘     └──────┘ └──────┘  │           │
│  │                                                       │           │
│  │  When spot reclaimed → NTH drains → pods reschedule  │           │
│  └─────────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Service Placement Matrix

| Service | Node Type | Replicas | PDB (minAvailable) | Stateful? | Why? |
|---------|-----------|----------|-------------------|-----------|------|
| **UI** (frontend) | ☀️ SPOT | 4 | 3 | No | User-facing, stateless Java app. Extra replicas for visibility. |
| **Cart** API | ☀️ SPOT | 3 | 2 | No | Stateless Spring Boot API. Cart data in DynamoDB (managed). |
| **Catalog** API | ☀️ SPOT | 3 | 2 | No | Stateless Go API. Product data read from MySQL. |
| **Checkout** API | ☀️ SPOT | 3 | 2 | No | Stateless NestJS API. Session state in Redis. |
| **Orders** API | ☀️ SPOT | 3 | 2 | No | Stateless Spring Boot API. Orders persisted in PostgreSQL. |
| MySQL (catalog DB) | 🔒 ON-DEMAND | 1 | N/A | **YES** | Database — data loss on spot reclaim. |
| PostgreSQL (orders DB) | 🔒 ON-DEMAND | 1 | N/A | **YES** | Database — data corruption on hard kill. |
| RabbitMQ (orders queue) | 🔒 ON-DEMAND | 1 | N/A | **YES** | Message broker — unacked messages lost. |
| Redis (checkout cache) | 🔒 ON-DEMAND | 1 | N/A | **YES** | Cache — in-flight checkout sessions lost. |
| DynamoDB Local (cart) | 🔒 ON-DEMAND | 1 | N/A | **YES** | Local DB emulator — ephemeral but still data. |
| CoreDNS | 🔒 ON-DEMAND | 2 | N/A | System | DNS dies → entire cluster can't resolve services. |
| Ingress Controller | 🔒 ON-DEMAND | 2 | N/A | System | Traffic ingress dies → all external access lost. |
| NTH | 🔒 ON-DEMAND | 1 | N/A | System | NTH dies on spot → no one handles the next reclaim. |
| ArgoCD | 🔒 ON-DEMAND | 2 | N/A | System | GitOps controller — must survive spot reclaims. |
| Prometheus/Grafana | 🔒 ON-DEMAND | varies | N/A | System | Monitoring — can't monitor spot events if monitoring is down. |

---

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

src/
├── ui/chart/values.yaml         # 4 replicas, spot, dual topology spread, PDB=3
├── cart/chart/values.yaml       # 3 replicas, spot, topology spread, PDB=2
├── catalog/chart/values.yaml    # 3 replicas, spot, topology spread, PDB=2
├── checkout/chart/values.yaml   # 3 replicas, spot, topology spread, PDB=2
├── orders/chart/values.yaml     # 3 replicas, spot, topology spread, PDB=2
└── app/chart/
    ├── values.yaml              # Umbrella chart default values
    └── values-stateful.yaml     # Overlay: enables DBs on On-Demand nodes

k8s/
├── spot-resilience/
│   └── deployment-template.yaml  # Service placement matrix documentation
└── monitoring/
    └── spot-alerts.yaml          # Prometheus alerting rules for spot events
```

---

## What Changed in Each Helm Chart

### Every Stateless Service (UI, Cart, Catalog, Checkout, Orders)

| Setting | Before | After | Why |
|---------|--------|-------|-----|
| `replicaCount` | `1` | `3` (UI: `4`) | Single replica + spot = downtime. Multiple replicas = zero-downtime during reclaim. |
| `nodeSelector` | `{}` (any node) | `{ role: spot-worker }` | Pin to spot nodes for 60-80% cost savings. |
| `affinity` | `{}` | Prefer `node.kubernetes.io/lifecycle: spot` | Soft preference — falls back to on-demand gracefully. |
| `topologySpreadConstraints` | `[]` | Spread across AZs | One spot reclaim in us-west-2a affects 1 pod, not all. |
| `podDisruptionBudget.enabled` | `false` | `true` | NTH respects PDBs — guarantees minimum pods during drain. |
| `podDisruptionBudget.minAvailable` | `2` (unused) | `2` (UI: `3`) | Active protection during spot reclaim events. |

### Every Stateful Backing Service (MySQL, PostgreSQL, RabbitMQ, Redis, DynamoDB Local)

| Setting | Before | After | Why |
|---------|--------|-------|-----|
| `nodeSelector` | `{}` (any node) | `{ role: system }` | Pin to On-Demand — spot reclaim = data loss. |
| `tolerations` | `[]` | CriticalAddonsOnly toleration | System nodes have a taint — stateful services must tolerate it. |

### `values-stateful.yaml` (Umbrella Override)

The overlay file now explicitly pins every backing service to system nodes with the correct tolerations, so even when deploying the full stateful stack, databases never land on spot instances.

---

## Cost Impact

| Component | Without Spot (On-Demand only) | With This Architecture | Monthly Savings |
|-----------|------------------------------|----------------------|-----------------|
| 16 app pods (5 services × ~3 each) | ~$200/mo | ~$50/mo (Spot) | **$150** |
| 5 stateful pods (DBs/caches) | ~$80/mo | ~$80/mo (On-Demand — stays same) | $0 |
| System pods (DNS, Ingress, NTH, etc.) | ~$60/mo | ~$60/mo (On-Demand — stays same) | $0 |
| CloudWatch vs Prometheus | ~$100/mo | $0 | **$100** |
| SQS + EventBridge | — | ~$0.01/mo | Negligible |
| **Total** | **~$440/mo** | **~$190/mo** | **~$250/mo (57%)** |

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

# 3. Verify node groups
kubectl get nodes -L role,node.kubernetes.io/lifecycle

# 4. Verify NTH is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-node-termination-handler

# 5. Deploy with Helm (in-memory mode)
cd ../src/app/chart
helm dependency update .
helm install retail-store . -f values.yaml

# 6. Deploy with Helm (stateful mode — DBs on On-Demand)
helm install retail-store . -f values.yaml -f values-stateful.yaml

# 7. Apply monitoring alerts
kubectl apply -f ../../../k8s/monitoring/spot-alerts.yaml

# 8. Get ArgoCD password
eval $(terraform output -raw argocd_initial_password_command)
```
