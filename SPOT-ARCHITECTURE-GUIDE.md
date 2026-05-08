# Production-Grade Spot Instance Resilience: DevOps Architecture Guide

This document is designed to serve as both a comprehensive technical guide for the Spot Instance architecture implemented in this project and a study guide for explaining this feature in DevOps or Cloud Engineering interviews.

---

## 1. The Elevator Pitch (How to introduce this in an interview)

**"In this project, I engineered a highly resilient, cost-optimized EKS architecture that runs stateless microservices on AWS Spot Instances, achieving up to 80% compute cost reduction without sacrificing uptime. I implemented an event-driven termination pipeline using EventBridge, SQS, and the AWS Node Termination Handler in Queue Processor mode. To ensure zero downtime, I strictly segregated stateful and critical infrastructure to On-Demand nodes using taints and tolerations, while configuring the stateless application layer with topology spread constraints and Pod Disruption Budgets to gracefully handle AWS's 2-minute spot reclamation warnings."**

---

## 2. The Problem We Are Solving

**The Challenge:**
Running Kubernetes clusters on On-Demand EC2 instances is expensive. Spot instances offer massive discounts (up to 80%), but AWS can pull the plug on them at any time with only a 2-minute warning. If a node is abruptly terminated, the pods running on it are killed instantly, leading to dropped HTTP requests, lost data, and poor user experience. Furthermore, running stateful workloads (like databases) or critical cluster addons (like CoreDNS or Ingress) on Spot instances is catastrophic if the node goes down.

**The Solution:**
Build a "Zero-Downtime Spot Migration" system that actively listens for AWS termination warnings, intercepts them, and gracefully moves workloads to healthy nodes *before* the hardware is actually reclaimed, while ensuring that databases never land on a Spot instance in the first place.

---

## 3. The Architecture & Event Flow

### The Infrastructure Split (Compute Strategy)
We don't just dump everything onto Spot. We split the compute layer into two Managed Node Groups:

1. **`system` (On-Demand):** The bedrock. This node group uses a Kubernetes Taint (`CriticalAddonsOnly=true:NoSchedule`). Only cluster-critical pods (CoreDNS, Ingress, ArgoCD, Prometheus) and **Stateful Databases** (MySQL, PostgreSQL, Redis) are allowed here.
2. **`spot_workers` (Spot):** The fleet. This group runs on 10 diverse instance types (e.g., t3, t3a, m5, m5a) to reduce the probability of simultaneous interruptions. This is where the stateless microservices (UI, Cart, Catalog, Checkout, Orders) live.

### The Event-Driven Pipeline (The 2-Minute Drill)
When AWS decides to take a Spot instance back, the following automated flow happens:

1. **T-120s (AWS sends the signal):** AWS emits a `Spot Interruption Warning` event to the default EventBridge bus.
2. **T-119s (EventBridge routing):** EventBridge rules match the event and forward it to a dedicated SQS Queue (`spot-termination`).
3. **T-118s (NTH Polls SQS):** The AWS Node Termination Handler (NTH) running on our *On-Demand* system nodes is constantly long-polling this SQS queue. It picks up the message.
4. **T-117s (Cordon):** NTH communicates with the Kubernetes API server and immediately `cordons` the targeted Spot node (marks it as `SchedulingDisabled`).
5. **T-115s (Drain & Graceful Shutdown):** NTH issues a `drain` command. The Kubernetes scheduler starts evicting pods. The pods receive a `SIGTERM` signal, stop accepting new traffic, finish their current requests, and gracefully shut down.
6. **T-110s (ASG Replacement):** The underlying Auto Scaling Group notices a node is terminating and provisions a new Spot instance from the diverse instance pool.
7. **T-80s (Rescheduling):** The evicted pods are rescheduled onto other existing healthy Spot nodes (or the newly booted one).
8. **T-30s (Lifecycle Hook Complete):** NTH tells the AWS ASG Lifecycle Hook to `CONTINUE`, allowing AWS to finally terminate the EC2 instance.
9. **T-0s (AWS Reclaims):** AWS terminates the instance. Our workloads were already safely migrated 60 seconds ago. Zero dropped connections.

---

## 4. Component Deep Dive

### A. The AWS Plumbing (Terraform)
Located in `spot-termination.tf`.
Instead of relying on the IMDSv1 metadata endpoint (which is a security risk and requires a DaemonSet on every node), we use **Queue Processor Mode**. 
* We created an **SQS Queue** with long polling (to reduce API costs).
* We created **EventBridge Rules** catching 4 types of events: Spot Interruptions, Rebalance Recommendations, Instance State Changes, and Scheduled Maintenance.
* We created **ASG Lifecycle Hooks** to pause the termination of the EC2 instance until NTH finishes its job.

### B. Security (IRSA)
Located in `irsa.tf`.
We adhere to the Principle of Least Privilege. The NTH pod needs permission to read SQS and complete ASG lifecycle hooks. Instead of hardcoding AWS access keys, we use **IAM Roles for Service Accounts (IRSA)**. The Kubernetes ServiceAccount is cryptographically tied to an AWS IAM Role via OIDC.

### C. The Application Layer Resilience (Helm)
Spot resilience isn't just an infrastructure problem; the applications must be configured to survive it. For all 5 stateless microservices in `src/`, we configured:
* **Multiple Replicas:** (e.g., 3 or 4). You cannot survive a node dying if you only have 1 replica.
* **Topology Spread Constraints:** We force the Kubernetes scheduler to spread the replicas across different Availability Zones (AZs). If an entire AZ runs out of Spot capacity, only 1/3 of our pods are affected.
* **Pod Disruption Budgets (PDB):** We set `minAvailable: 2`. When NTH tries to drain a node, the PDB prevents Kubernetes from evicting too many pods at once, guaranteeing the service stays online during the migration.
* **Node Affinity:** A soft preference (`preferredDuringSchedulingIgnoredDuringExecution`) for Spot nodes. If AWS completely runs out of Spot capacity globally, the pods will seamlessly fall back to On-Demand nodes rather than being stuck in a `Pending` state.

---

## 5. Interviewer Q&A: How to Defend This Architecture

If you are explaining this project in an interview, be prepared for these questions:

**Interviewer: "Why did you use SQS and EventBridge (Queue Processor mode) instead of just running NTH as a DaemonSet (IMDS mode)?"**
> *Your Answer:* "Running NTH as a DaemonSet relies on the EC2 instance metadata service (IMDS). If a node is under heavy CPU load, the DaemonSet might fail to query the metadata in time. Also, IMDS mode only catches Spot interruptions. Queue Processor mode via SQS is much more robust: it runs centrally on the stable On-Demand nodes, handles ASG Lifecycle Hooks, catches Rebalance Recommendations (giving us *more* than 2 minutes warning), and scales better for large clusters without wasting resources on every worker node."

**Interviewer: "What happens if you run a database on a Spot instance?"**
> *Your Answer:* "Absolute disaster. When the Spot instance is reclaimed, the pod is killed. If it's a database like PostgreSQL or MySQL, terminating the process abruptly can corrupt the Write-Ahead Log (WAL), and because the local disk is destroyed, any un-replicated data is permanently lost. That's exactly why I engineered the compute split: I used a Kubernetes Taint (`CriticalAddonsOnly`) on the On-Demand node group and explicitly pinned all stateful workloads (MySQL, Redis, RabbitMQ) to those stable nodes using Tolerations and NodeSelectors. Databases never touch Spot."

**Interviewer: "How do you ensure your application doesn't drop requests during the 2-minute drain window?"**
> *Your Answer:* "It's a combination of infrastructure and app configuration. First, NTH cordons the node so no *new* traffic is routed to it. Then, Kubernetes sends a `SIGTERM` to the pods. Our deployments are configured with graceful shutdown and readiness probes. The app stops accepting new connections, finishes processing the current HTTP requests, and then exits. Meanwhile, our Pod Disruption Budgets (PDBs) guarantee that a minimum number of replicas remain active across other Availability Zones (enforced by Topology Spread Constraints) to handle the incoming traffic."

**Interviewer: "What if AWS completely runs out of Spot capacity in your region?"**
> *Your Answer:* "Our architecture degrades gracefully. First, we use a diverse pool of 10 different instance types (t3, m5 families) across multiple AZs, which makes a total Spot drought highly unlikely. However, if it does happen, our Helm charts use *soft* Node Affinity (`preferredDuringScheduling...`). The Kubernetes scheduler will try to put the stateless pods on Spot, but if no Spot nodes are available, it will fall back to scheduling them on the On-Demand system nodes. We might pay more temporarily, but the application stays online."

---

## Summary of Impact
By implementing this feature, you transformed a standard, fragile Kubernetes deployment into a **Tier-1, Production-Grade architecture**. You demonstrated knowledge of AWS compute economics, event-driven serverless routing (EventBridge/SQS), Kubernetes scheduling primitives (Taints, Tolerations, Affinity, Topology Spread), and Site Reliability Engineering principles (PDBs, Graceful Degradation).
