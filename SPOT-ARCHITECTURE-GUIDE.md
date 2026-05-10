# Production-Grade Spot Instance Resilience: DevOps Architecture Guide

This document is designed to serve as both a comprehensive technical guide for the Spot Instance architecture implemented in this project and a study guide for explaining this feature in DevOps or Cloud Engineering interviews.

---

## 1. The Elevator Pitch (How to introduce this in an interview)

**"In this project, I engineered a highly resilient, cost-optimized EKS architecture that runs stateless microservices on AWS Spot Instances, achieving up to 80% compute cost reduction without sacrificing uptime. I implemented Karpenter for intelligent, just-in-time node provisioning with native spot interruption handling via an EventBridge → SQS pipeline. To ensure zero downtime, I strictly segregated stateful and critical infrastructure to On-Demand nodes using taints and tolerations, while configuring the stateless application layer with topology spread constraints and Pod Disruption Budgets. Karpenter picks from 10+ instance families, consolidates underutilized nodes automatically, and handles spot reclaims before they impact running workloads."**

---

## 2. The Problem We Are Solving

**The Challenge:**
Running Kubernetes clusters on On-Demand EC2 instances is expensive. Spot instances offer massive discounts (up to 80%), but AWS can pull the plug on them at any time with only a 2-minute warning. If a node is abruptly terminated, the pods running on it are killed instantly, leading to dropped HTTP requests, lost data, and poor user experience. Furthermore, running stateful workloads (like databases) or critical cluster addons (like CoreDNS or Ingress) on Spot instances is catastrophic if the node goes down.

**Traditional ASG-Based Approach (What We Replaced):**
The old approach used fixed Auto Scaling Groups (ASGs) with the AWS Node Termination Handler (NTH) polling an SQS queue. While functional, this had limitations:
- ASGs are slow to react (launch template changes, ASG warmup delays)
- Instance type diversity is limited to the ASG's launch template
- No automatic bin-packing or consolidation — you pay for idle capacity
- A separate controller (NTH) was needed just for graceful draining

**The Karpenter Solution (Current Architecture):**
Karpenter replaces both the ASG and NTH with a single controller that:
- Provisions nodes directly via EC2 RunInstances (no ASG lag)
- Evaluates 50+ instance type candidates across 10 families and picks the cheapest available spot instance that fits pending pod requirements
- Natively handles spot interruption events from the same SQS queue
- Actively consolidates underutilized nodes — replaces them with smaller/fewer ones to maximize bin-packing and minimize cost

---

## 3. The Architecture & Event Flow

### The Infrastructure Split (Compute Strategy)

We don't just dump everything onto Spot. We split the compute layer into two categories:

1. **`system` Node Group (On-Demand, EKS Managed):** The bedrock. This node group uses a Kubernetes Taint (`CriticalAddonsOnly=true:NoSchedule`). Only cluster-critical pods (CoreDNS, Traefik, ArgoCD, Prometheus, Karpenter itself, KEDA) are allowed here. These nodes must **never** be interrupted.

2. **Karpenter-Provisioned Nodes (Spot-Preferred):** The dynamic fleet. Karpenter provisions nodes from 10 diverse instance families (m5, m5a, m5d, m6i, m6a, m4, r5, r6i, c5, c6i) across multiple sizes. This is where stateless microservices (UI, Cart, Catalog, Checkout, Orders) live. Karpenter picks the optimal instance type per workload, preferring spot (weight 80) but falling back to on-demand if spot capacity is unavailable.

### The Event-Driven Pipeline (Spot Interruption Handling)

```
┌──────────────────────┐     ┌──────────────┐     ┌───────────────────┐
│   AWS EC2 Service    │     │  EventBridge  │     │    SQS Queue      │
│                      │────▶│  (4 rules)    │────▶│  (spot-term)      │
│ • Spot Interruption  │     │               │     │                   │
│ • Rebalance          │     └──────────────┘     └─────────┬─────────┘
│ • State Change       │                                     │
│ • Scheduled Maint.   │                                     ▼
└──────────────────────┘                          ┌───────────────────┐
                                                  │    Karpenter      │
                                                  │  Controller Pod   │
                                                  │  (On-Demand node) │
                                                  └─────────┬─────────┘
                                                            │
                                                  ┌─────────▼─────────┐
                                                  │ 1. Cordon node    │
                                                  │ 2. Launch replace │
                                                  │ 3. Drain old node │
                                                  │ 4. Terminate old  │
                                                  └───────────────────┘
```

When AWS decides to reclaim a Spot instance:

1. **T-120s (AWS sends the signal):** AWS emits a `Spot Interruption Warning` event to the default EventBridge bus.
2. **T-119s (EventBridge routing):** EventBridge rules match the event and forward it to a dedicated SQS Queue (`spot-termination`).
3. **T-118s (Karpenter receives it):** The Karpenter controller running on *On-Demand* system nodes is polling this SQS queue via `settings.interruptionQueue`. It picks up the message.
4. **T-117s (Replacement launched):** Karpenter immediately begins launching a replacement node, picking the optimal instance type from its 50+ candidates based on pending pod requirements and current spot pricing.
5. **T-115s (Cordon & Drain):** Karpenter cordons the targeted node (marks it as `SchedulingDisabled`) and begins draining pods. Pods receive `SIGTERM`, stop accepting new traffic, finish current requests, and gracefully shut down.
6. **T-80s (Rescheduling):** Evicted pods are rescheduled onto the replacement node or other healthy nodes. Karpenter's bin-packing ensures efficient placement.
7. **T-0s (AWS Reclaims):** AWS terminates the instance. Workloads were safely migrated 60+ seconds ago. Zero dropped connections.

### Key Difference from NTH:
Karpenter doesn't just drain — it **proactively provisions replacement capacity** before the drain completes. With NTH, you had to wait for the ASG to notice the terminated instance, launch a new one, and wait for it to join the cluster. Karpenter eliminates that delay entirely.

---

## 4. Component Deep Dive

### A. The AWS Plumbing (Terraform)
Located in `spot-termination.tf`.

The EventBridge → SQS pipeline catches spot interruption signals and feeds them to Karpenter:
* **SQS Queue** with long polling (reduces API costs) and 5-min message retention (events are time-critical)
* **4 EventBridge Rules** catching: Spot Interruptions, Rebalance Recommendations, Instance State Changes, and Scheduled Maintenance
* **SQS Queue Policy** allowing EventBridge to push messages

This pipeline was originally built for NTH and is now consumed by Karpenter — no changes were needed to the AWS-side plumbing.

### B. Karpenter Controller (Terraform + Kubernetes)
Located in `karpenter.tf`, `karpenter-nodeclass.yaml`, `karpenter-nodepool.yaml`.

**IRSA (IAM Role for Service Account):**
Karpenter's controller pod assumes an AWS IAM role via OIDC federation. This role has least-privilege permissions scoped to:
- `ec2:RunInstances/TerminateInstances` — launch and kill nodes
- `ec2:Describe*` — discover instance types, subnets, security groups, AMIs
- `sqs:ReceiveMessage/DeleteMessage` — consume the interruption queue
- `iam:PassRole` — scoped to the node instance role only
- `ssm:GetParameter` — resolve AL2 AMI via SSM alias
- `eks:DescribeCluster` — discover cluster endpoint and CA

**EC2NodeClass** (`karpenter-nodeclass.yaml`):
Defines *how* nodes are configured — the "launch template" equivalent:
- Subnets and security groups discovered by tags (same as existing nodegroup)
- AMI: Amazon Linux 2 via SSM alias (`al2@latest`)
- IMDSv2 enforced (security best practice)
- Encrypted gp3 root volumes

**NodePool** (`karpenter-nodepool.yaml`):
Defines *what* Karpenter is allowed to provision — the "policy" layer:
- 10 instance families: m5, m5a, m5d, m6i, m6a, m4, r5, r6i, c5, c6i
- Capacity preference: spot (weight 80) with on-demand fallback
- Resource limits: 1000 vCPU, 4000Gi memory across all Karpenter-managed nodes
- Consolidation: `WhenUnderutilized` with 30s settle time
- Disruption budget: max 20% of nodes disrupted simultaneously
- Zero-disruption window: 02:00–04:00 UTC daily (protects batch jobs/ETL)

### C. The Application Layer Resilience (Helm)
Spot resilience isn't just an infrastructure problem; the applications must be configured to survive it. For all 5 stateless microservices in `src/`, we configured:
* **Multiple Replicas:** (e.g., 3 or 4). You cannot survive a node dying if you only have 1 replica.
* **Topology Spread Constraints:** Force the Kubernetes scheduler to spread replicas across different Availability Zones (AZs). If an entire AZ runs out of Spot capacity, only 1/3 of pods are affected.
* **Pod Disruption Budgets (PDB):** Set `minAvailable: 3` (UI) or `minAvailable: 2` (backends). When Karpenter consolidates or drains a node, the PDB prevents too many pods from being evicted at once.
* **Node Affinity:** A soft preference (`preferredDuringSchedulingIgnoredDuringExecution`) for Spot nodes. If spot capacity is exhausted, pods fall back to On-Demand rather than being stuck in `Pending`.

---

## 5. Karpenter Consolidation — How It Saves Money Automatically

Unlike ASG-based scaling (which only scales on CloudWatch alarms), Karpenter actively watches for waste:

```
BEFORE consolidation:          AFTER consolidation:
┌──────────────┐               ┌──────────────┐
│  m5.xlarge   │               │  m5.large    │
│  (4 vCPU)    │               │  (2 vCPU)    │
│  [pod: 0.5]  │               │  [pod: 0.5]  │
│  [pod: 0.5]  │───────┐      │  [pod: 0.5]  │
│  idle: 3.0   │       │      │  [pod: 0.5]  │
└──────────────┘       │      │  [pod: 0.5]  │
                       │      │  idle: 0.5   │  ← much less waste
┌──────────────┐       │      └──────────────┘
│  m5.large    │       │
│  (2 vCPU)    │       │      Node terminated,
│  [pod: 0.5]  │───────┘      pods re-packed
│  idle: 1.5   │
└──────────────┘
```

Karpenter detects that two nodes are underutilized, launches one right-sized replacement, moves pods, and terminates the old nodes. This happens automatically every 30 seconds.

---

## 6. Interviewer Q&A: How to Defend This Architecture

If you are explaining this project in an interview, be prepared for these questions:

**Interviewer: "Why did you switch from NTH + ASG to Karpenter?"**
> *Your Answer:* "NTH is reactive — it waits for AWS to send a 2-minute warning, then drains. ASGs are slow to replace nodes because they go through launch template evaluation, AZ rebalancing, and warmup periods. Karpenter is both proactive and reactive. It consumes the same SQS interruption events, but it also launches replacement capacity *before* the drain completes. Additionally, Karpenter does bin-packing and consolidation — it actively replaces underutilized nodes with right-sized ones. With NTH+ASG, you'd have idle capacity sitting around costing money. Karpenter eliminates that."

**Interviewer: "How does Karpenter pick which instance type to use?"**
> *Your Answer:* "Karpenter evaluates all allowed instance types (we permit 10 families × multiple sizes = 50+ candidates), checks current spot pricing and availability across all AZs, and picks the cheapest instance that fits the pending pod's resource requests. It uses a concept called 'instance type flexibility' — more candidates means lower interruption rates and better pricing. It also factors in the EC2 fleet API to maximise the chance of getting spot capacity."

**Interviewer: "What happens if you run a database on a Spot instance?"**
> *Your Answer:* "Absolute disaster. When the Spot instance is reclaimed, the pod is killed. If it's a database like PostgreSQL or MySQL, terminating the process abruptly can corrupt the Write-Ahead Log (WAL), and because the local disk is destroyed, any un-replicated data is permanently lost. That's exactly why I engineered the compute split: I used a Kubernetes Taint (`CriticalAddonsOnly`) on the On-Demand node group and explicitly pinned all stateful workloads (MySQL, Redis, RabbitMQ) to those stable nodes using Tolerations and NodeSelectors. Databases never touch Spot."

**Interviewer: "How do you ensure your application doesn't drop requests during a spot reclaim?"**
> *Your Answer:* "It's a combination of Karpenter behavior and app configuration. First, Karpenter launches a replacement node immediately on receiving the interruption signal — so there's capacity ready. Then it cordons the old node and drains pods. Our deployments use graceful shutdown (SIGTERM handling, readiness probes) so the app stops accepting new connections and finishes in-flight requests. Pod Disruption Budgets ensure a minimum number of replicas stay active. Topology Spread Constraints guarantee those remaining replicas are in different AZs. The combination means zero dropped requests."

**Interviewer: "What if AWS completely runs out of Spot capacity?"**
> *Your Answer:* "Our NodePool allows both spot and on-demand capacity types. Karpenter prefers spot (weight 80) but will fall back to on-demand automatically if spot is unavailable. With 10 instance families across 3 AZs, a total spot drought is extremely unlikely, but the fallback means the application stays online — we just pay more temporarily. We also have resource limits (1000 vCPU / 4000Gi) on the NodePool to prevent runaway scaling in either capacity type."

**Interviewer: "How does consolidation work without disrupting running services?"**
> *Your Answer:* "Karpenter has disruption budgets. We configured max 20% of nodes to be disrupted simultaneously, and a zero-disruption window between 02:00–04:00 UTC for batch jobs. When consolidating, Karpenter respects PDBs — it won't evict a pod if doing so would violate the budget. It also uses the `consolidateAfter: 30s` setting, meaning a node must be underutilized for at least 30 seconds before Karpenter acts. This prevents thrashing during normal scaling events."

---

## 7. Summary of Impact

By implementing this architecture, you transformed a standard, fragile Kubernetes deployment into a **Tier-1, Production-Grade platform**. You demonstrated knowledge of:

| Area | What You Implemented |
|------|---------------------|
| **AWS Compute Economics** | Spot instances with 10-family diversity, automatic fallback to on-demand |
| **Modern Autoscaling** | Karpenter just-in-time provisioning with bin-packing and consolidation |
| **Event-Driven Architecture** | EventBridge → SQS pipeline for real-time interruption handling |
| **Kubernetes Scheduling** | Taints, Tolerations, Affinity, Topology Spread Constraints |
| **SRE Principles** | PDBs, graceful degradation, disruption budgets, zero-disruption windows |
| **Security** | IRSA (no hardcoded credentials), IMDSv2 enforcement, least-privilege IAM |
| **Infrastructure as Code** | Terraform for all AWS resources, Helm for Kubernetes deployments |
