# DevOps Interview Answers - Retail Cloud-Native Platform

**Interviewer:** Principal DevOps Engineer at Sparrow Cloud  
**Candidate Profile:** Production-Grade EKS Architecture with Karpenter Spot Optimization

---

## Round 1 Answers — Project Overview & Architecture

### A1.1 Cluster Architecture Strategy

**Direct Answer:**
Segregating system nodes (On-Demand, tainted) from app nodes (Spot, Karpenter-managed) provides **fault isolation and cost optimization** without sacrificing availability. This is a proven pattern at scale (Zomato, Booking.com, Netflix).

**Deep Explanation:**

The segregation serves multiple purposes:

1. **Availability**: Critical cluster components (CoreDNS, Traefik, Karpenter controller, Prometheus) run on nodes that AWS will never interrupt. A spot reclaim affecting 10 app nodes shouldn't impact DNS resolution.

2. **Cost**: Stateless workloads (cart, catalog, checkout) can be arbitrarily rescheduled. They're perfect for spot. System components need predictable placement. This mix achieves ~70% spot utilization while keeping core services stable.

3. **Compliance**: In regulated industries (healthcare, finance), critical infrastructure often requires On-Demand guarantees. This architecture separates concerns cleanly.

**Why Not A Simpler Approach?**
- **Single On-Demand cluster**: Zero interruptions, but 3-5x more expensive. A $10K/month cluster becomes $30-50K.
- **All spot**: Maximum savings, but any spot reclaim can cascade. Single catastrophic risk.
- **Mixed without segregation**: Spots can evict critical pods. Karpenter would have to rebuild Prometheus/ArgoCD too.

**Cost-Benefit Tradeoff:**

For a $10K/month cluster (200 nodes at $50/month each):
- All On-Demand: $10K/month
- 70% spot: $5K on-demand (system) + $2K spot (app) = $7K/month
- **Savings: $3K/month, ~30% reduction**

But operational cost of managing spot:
- Karpenter controller (development/ops time)
- Monitoring spot events and MTTR if consolidation causes issues
- Testing and validation of spot behavior

**Break-even:** Usually within 6 months of operational overhead. Beyond that, pure savings.

**When Tradeoff Breaks Down:**

1. **Low traffic clusters** (<$2K/month): Overhead > savings. Use pure On-Demand.
2. **Stateful workloads**: Databases, caches. Spot interruption = data loss risk. Keep these On-Demand.
3. **Compliance-heavy orgs**: Requires audit trail for every instance. Spot churn means more audit entries.
4. **Regions with poor spot availability**: Some regions/AZs have low spot capacity. Diversity strategy fails.

**Production Considerations:**

This architecture assumes:
- Stateless app design (non-negotiable)
- Proper pod disruption budgets (prevents all pods from crashing simultaneously)
- Monitoring of interruption events (detect if spot becomes unreliable)
- SLA acceptance (site *might* be slow during mass reclaim, but won't be down)

---

### A1.2 Spot Instance Economics

**Math Breakdown:**

Assume: 10 cart pods, each 256m CPU. In AWS us-west-2:
- **On-Demand t3.medium**: $0.0416/hour × 240 hours/month = $10/month per instance
- **Spot t3.medium**: $0.0125/hour (70% discount) = $3/month per instance

For 10 nodes:
- All On-Demand: 10 × $10 = $100/month
- 70% Spot (7 spot + 3 on-demand): 7 × $3 + 3 × $10 = $51/month
- **Savings: $49/month per 10 nodes**

Scaling to full cluster (system + app + monitoring):
- **System nodes**: 2 On-Demand (non-negotiable) = $20/month
- **App nodes**: 10 average, 70% spot = $51/month
- **Monitoring nodes**: 2 On-Demand (Prometheus needs reliable storage) = $20/month
- **Total**: ~$91/month

All On-Demand equivalent: $300/month
**Total savings: 70% — exactly as advertised**

**Communication to Finance:**

"We're spending $91/month on compute vs. $300/month for guaranteed availability. We accept 2 spot reclaims per month (2% probability from AWS data), each costing us 5-10 minutes of degraded performance. The average revenue loss during a 5-minute incident is $X. Our ROI is positive at $(300-91)/month = $209/month or $2,508/year savings minus operational overhead of maybe $500/year = $2,000 net annual savings."

**When Spot Breaks:**

If spot interruption rate spikes (e.g., AWS needs capacity during a regional event):
1. **Week 1**: Alert on 5+ interruptions/day (vs. baseline 2-3)
2. **Week 2**: Switch to pure On-Demand temporarily (cost spike, but service stable)
3. **Root cause**: AWS capacity issue (typically resolves in days)
4. **Post-analysis**: Did we lose revenue? Was SLA violated? Update financial model.

At some point (maybe 10% of month), the interruption cost exceeds savings. At that point, hybrid isn't working; pivot to On-Demand-only.

---

### A1.3 Microservices State Design

**The Cart State Problem:**

User adds an item to cart during a spot reclaim:
```
Time 0: User clicks "add to cart" (item #12345)
Time 100ms: Cart pod receives request
Time 150ms: Cart pod calls DynamoDB: putItem(userId, item)
Time 300ms: DynamoDB acknowledges (item persisted)
Time 400ms: Cart pod responds to user ("item added!")
Time 1000ms: AWS spot interruption signal fires (2-min warning)
Time 1120ms: Karpenter cordons node, begins drain
Time 1500ms: Cart pod receives SIGTERM, graceful shutdown initiated
Time 1800ms: Pod terminates, AWS reclaims node
```

**Result**: Item was already in DynamoDB at time 300ms. Pod crash at time 1800ms doesn't affect that data.

**The Critical Part**: The state store (DynamoDB) is *outside* the spot node. The spot node holds ZERO permanent data. This is the fundamental design constraint for spot safety.

**Where State Actually Lives:**

```yaml
# cart service flow
cart pod → HTTP → DynamoDB (AWS managed, highly durable)
      ↓
    In-memory cache (expires after 5 min, OK to lose)
      ↓
    Session store (Redis, also On-Demand node or AWS ElastiCache)
```

**If State Store Becomes Unavailable:**

During a Karpenter consolidation wave (e.g., replacing 5 nodes with 3 smaller ones):
1. 15 pods are evicted (across 5 nodes)
2. Pods reschedule on 3 replacement nodes
3. Pods reconnect to DynamoDB (connection pool reset)
4. If DynamoDB is down: All 15 pods fail to reconnect, error 500

**Mitigation:**
- DynamoDB is AWS-managed (99.99% SLA), not in cluster
- Circuit breakers in cart pod (fail fast instead of hanging)
- Retry logic with exponential backoff
- Alerts if DynamoDB latency spikes

**Production Reality:**

In reality, state is usually distributed:
- **Hot data** (current cart, current session): Redis (On-Demand node or ElastiCache)
- **Warm data** (order history): RDS PostgreSQL (managed AWS)
- **Cold data** (analytics): S3

The Karpenter design only affects the **compute layer** (cart pods). Data layer (Redis, RDS, S3) is unchanged.

---

### A1.4 Architecture Diagram Discrepancies

**The Edge Case:**

Some AWS regions have fewer than 3 AZs:
- **us-west-1**: 2 AZs (California)
- **ca-central-1**: 3 AZs (Canada)
- **ap-southeast-1**: 3 AZs (Singapore)

If someone tries to deploy to us-west-1:

```hcl
# terraform/locals.tf
azs = slice(data.aws_availability_zones.available.names, 0, 3)
```

**What happens:**
```
data.aws_availability_zones.available.names = ["us-west-1a", "us-west-1b"]
azs = slice([...], 0, 3) = slice([...], 0, 2) = ["us-west-1a", "us-west-1b"]
```

Slice doesn't fail if you ask for more than available—it just returns what exists. **So it degrades gracefully to 2 AZs.**

**Computed Subnets:**
```hcl
private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 10)]
```
With 2 AZs:
- private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

**Result**: Works fine. VPC is created with 2 AZs, subnets are /24 size, everything is valid.

**Validation Gap:**

The code doesn't validate that AZs were reduced. This is OK for most cases (2 or 3 AZs both work), but risky if:
- **Topology spread constraint expects 3 AZs**: Pod scheduling might fail
- **Disaster recovery plan assumes 3 AZs**: Single AZ failure would lose majority

**Better Approach:**

```hcl
variable "availability_zones" {
  type = number
  default = 3
  
  validation {
    condition = var.availability_zones >= 2 && var.availability_zones <= 4
    error_message = "AZs must be between 2 and 4"
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zones)
}
```

Or add a validation:

```hcl
resource "null_resource" "validate_azs" {
  count = length(local.azs) < 3 ? 1 : 0
  
  provisioner "local-exec" {
    command = "echo 'Warning: Deploying with < 3 AZs' >&2"
  }
}
```

**Production Impact:**

In practice, 2-AZ deployments are suboptimal but not catastrophic:
- Topology spread constraint will spread across 2 AZs instead of 3 (OK, still resilient)
- A-Z failure takes out 50% of capacity instead of 33% (acceptable risk)
- SLA should reflect this (e.g., "99.5% uptime, not 99.9%")

---

### A1.5 Cluster Naming & Uniqueness

**Why Random Suffix?**

The `random_string.suffix` prevents name collisions when running multiple Terraform deployments in the same AWS account:

```hcl
locals {
  cluster_name = "${var.cluster_name}-${random_string.suffix.result}"
}
# Possible names: "retail-store-abc1", "retail-store-xyz9"
```

Without the suffix:
```hcl
locals {
  cluster_name = var.cluster_name  # Always "retail-store"
}
```

**If you run `terraform apply` twice:**
1. First apply: Creates "retail-store" cluster
2. Second apply: Tries to create "retail-store" again → CONFLICT (cluster with that name already exists)

**With suffix:**
1. First apply: Creates "retail-store-abc1"
2. Second apply: Suffix randomizes to "xyz9", creates "retail-store-xyz9" → Success (orthogonal names)

**The Terraform Destroy + Re-apply Problem:**

```bash
# Day 1
terraform apply
# Cluster "retail-store-abc1" created
# suffix stored in state

# Day 2: terraform destroy fails (network issue, manual cleanup, etc.)
terraform destroy
# Partially failed, some resources remain

# Day 3: terraform apply (to recover)
terraform apply
# New suffix generated (e.g., "xyz9")
# Tries to create "retail-store-xyz9"
# But "retail-store-abc1" still exists in AWS (orphaned)
```

**Result**: You have orphaned clusters. This is wasteful but not catastrophic if you notice.

**Better Solution:**

Instead of random suffix, use deterministic naming:

```hcl
variable "environment" {
  type = string
  default = "dev"
}

locals {
  cluster_name = "${var.cluster_name}-${var.environment}-${var.aws_region}"
}
# Result: "retail-store-dev-us-west-2"
```

**Advantages:**
- Predictable names (easier to find resources)
- No orphaned clusters (same name on re-apply)
- Multi-environment friendly (can have retail-store-dev, retail-store-staging, retail-store-prod)

**Is Random Suffix Production-Safe?**

**Not really.** It's better suited for:
- **Rapid prototyping**: Spin up multiple test clusters, don't worry about cleanup
- **Ephemeral infra**: CI/CD jobs that create/destroy clusters in seconds

For **production**, you want:
- Deterministic naming
- Explicit state management (don't let Terraform manage cluster lifecycle alone)
- Separate Terraform workspaces for dev/staging/prod

**Recommended Approach for Prod:**

```bash
terraform workspace new prod
terraform workspace select prod

# In terraform variables:
environment = "prod"
# Result: cluster named "retail-store-prod-us-west-2"

terraform apply  # Same name every time in workspace prod
```

This gives you:
- Separate state files per environment (state.prod.tfstate)
- Deterministic naming
- Easy disaster recovery (re-apply with same name)

---

## Round 2 Answers — Kubernetes & Node Management

### A2.1 Taint Propagation Strategy

**Which Addons Get Toleration?**

EKS automatically adds the toleration for system addons. When you create the system node group with taint `CriticalAddonsOnly=true:NoSchedule`, EKS knows to:

1. **Managed addons** (coredns, kube-proxy, vpc-cni, eks-pod-identity-agent) automatically get:
   ```yaml
   tolerations:
   - key: CriticalAddonsOnly
     operator: Equal
     value: "true"
     effect: NoSchedule
   ```

2. **Additional addons** you deploy (Prometheus, Traefik) need explicit tolerations.

**In addons.tf, Traefik is pinned to system nodes:**

```hcl
set {
  name  = "nodeSelector.role"
  value = "system"
}

set {
  name  = "tolerations[0].key"
  value = "CriticalAddonsOnly"
}
```

**If Prometheus Doesn't Have the Toleration:**

```bash
kubectl get pods -n monitoring prometheus-server-0
# STATUS: Pending

kubectl describe pod prometheus-server-0
# Tolerations: none found
# Events: ...0 nodes are available with taints: {CriticalAddonsOnly: NoSchedule}
```

**Result**: Prometheus can't schedule on system nodes, and there are no other nodes available (app nodes don't have CriticalAddonsOnly toleration). Pod stays Pending forever.

**Debugging:**

```bash
# Check if addon is deployed correctly
helm list -n monitoring
# If missing, install it

# If installed but pending, check tolerations
kubectl get deployment prometheus-operator -n monitoring -o yaml | grep -A 5 tolerations

# Check node labels/taints
kubectl describe node <system-node-name>
# Taints: CriticalAddonsOnly=true:NoSchedule

# Solution: Add toleration to Helm values
helm upgrade prometheus-community/kube-prometheus-stack \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Equal \
  --set tolerations[0].value=true \
  --set tolerations[0].effect=NoSchedule
```

**Critical Addon Pattern:**

The CriticalAddonsOnly taint is Kubernetes convention for "only run pods that are essential to cluster function here." It's enforced by:
- Kubernetes scheduler (respects taints)
- Pod Priority (if a critical pod is evicted, it gets re-scheduled first)
- Kubelet eviction policy (doesn't evict critical pods unless memory critical)

**In Production:**

You'd also want:
```yaml
podPriority:
  priorityClassName: system-cluster-critical  # or system-node-critical
```

This ensures Prometheus stays on the system node even if memory is running low.

---

### A2.2 Node Lifecycle & Spot Interruption - Failure Modes

**Scenario 1: Karpenter Pod on Doomed Node**

```
Spot interruption warning fires for node-X (where Karpenter pods run)
Karpenter controller pod receives termination signal
Karpenter tries to cordon/drain other nodes (but it's shutting down)
Race condition: Does Karpenter finish reconciling before dying?
```

**This is CRITICAL.** If Karpenter dies:
1. No new nodes provisioned (Karpenter doesn't reschedule old nodes alone)
2. Pending pods stay Pending
3. No pod eviction/rescheduling
4. Cluster degrades until Karpenter restarts

**Mitigation:**
- **Replica count**: Run 3 Karpenter controller replicas on **different system nodes** (podAntiAffinity)
- **Node affinity**: Pin Karpenter to system nodes (taint + toleration) to ensure it's not evicted
- **Priority class**: Mark Karpenter as system-node-critical

```yaml
# Karpenter deployment (via Terraform)
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app.kubernetes.io/name
          operator: In
          values: ["karpenter"]
      topologyKey: kubernetes.io/hostname
nodeSelector:
  role: system
tolerations:
- key: CriticalAddonsOnly
  operator: Equal
  value: "true"
  effect: NoSchedule
priorityClassName: system-node-critical
```

**Scenario 2: All Karpenter Replicas on Doomed Nodes**

```
EventBridge fires: Spot interruption on node-X, node-Y, node-Z
All 3 system nodes are interrupted simultaneously (AZ-wide outage)
All 3 Karpenter replicas lose their nodes
Karpenter controller is gone
Cluster can't provision new nodes or drain workloads
```

**This is CATASTROPHIC but very unlikely (would require AZ-wide spot shortage).**

**Mitigation:**
- Deploy Karpenter to 3 nodes across 3 AZs (built-in by EKS default)
- If one AZ is reclaimed, Karpenter still runs on nodes in other AZs

**Scenario 3: Replacement Node Fails to Become Ready**

```
Karpenter launches replacement node for node-A
Node boots, but fails health checks (e.g., security group blocks kubelet)
Node stays NotReady for 15 minutes
Meanwhile, original node is still being drained
Pods have nowhere to go
```

**Debugging:**
```bash
kubectl get nodes
# STATUS: NotReady

kubectl describe node <new-node>
# Conditions: NotReady (KubeletNotReady, RuntimeNetworkNotReady)

# Check kubelet logs
ssh <node-ip>
sudo journalctl -u kubelet -n 50
# Error: Unable to register with API server: connection refused
```

**Common causes:**
- Security group blocks 443 (kubelet to API server)
- Network plugin (vpc-cni) not running
- Insufficient IAM permissions (node can't pull ECR images)

**Scenario 4: Pod with 1-Hour Termination Grace Period**

```yaml
terminationGracePeriodSeconds: 3600  # 1 hour!
```

```
Spot interruption on node-X
Karpenter cordons node-X
Karpenter begins draining pods
Pod receives SIGTERM, enters graceful shutdown
Pod says "I need 1 hour to gracefully shut down"
Karpenter must wait 1 hour before force-killing
But 2-minute warning expires at 2 minutes
AWS forcefully terminates node-X anyway
```

**Result**: Pod is KILL -9'd mid-transaction. Data loss.

**Mitigation:**
- Set reasonable `terminationGracePeriodSeconds` (30-60s, not 3600s)
- Use `preStop` hooks instead of relying on signal handling
- Drain should respect PDB timeout (don't wait longer than necessary)

```yaml
terminationGracePeriodSeconds: 45
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5 && /app/graceful-shutdown.sh"]
```

---

### A2.3 Pod Disruption Budgets (PDBs) - Deep Dive

**Scenario: 3 Replicas, maxUnavailable: 2, 5 Nodes Reclaimed**

```yaml
kind: PodDisruptionBudget
metadata:
  name: cart
spec:
  maxUnavailable: 2  # At most 2 pods unavailable
  selector:
    matchLabels:
      app: cart
```

**Initial state:**
- 3 cart pods running (one on each node: node-A, node-B, node-C)
- 2 additional nodes: node-D, node-E (no cart pods)

**5 nodes reclaimed simultaneously:**

```
Karpenter receives: node-A, node-B, node-C, node-D, node-E all interrupting

Eviction attempt for cart pods:
- Pod on node-A: Evict? Check PDB: 0 unavailable now, can evict 2. YES. (unavailable: 1)
- Pod on node-B: Evict? Check PDB: 1 unavailable now, can evict 2. YES. (unavailable: 2)
- Pod on node-C: Evict? Check PDB: 2 unavailable now, can evict 2. NO. Pod stays.

Result: 2 cart pods evicted, 1 stays on node-C
Pod on node-C reschedules to replacement node
```

**BUT WAIT**: If node-D and node-E are also reclaimed, and they contain other critical pods:

```
Karpenter eviction logic respects PDB per app
- Evict 2 cart pods (PDB allows it)
- Evict 1 prometheus pod IF prometheus PDB allows (might block for availability)
- Can't evict everything at once
```

**PDB Interaction with HPA:**

```yaml
kind: HorizontalPodAutoscaler
metadata:
  name: cart
spec:
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
---
kind: PodDisruptionBudget
metadata:
  name: cart
spec:
  maxUnavailable: 1
```

**Scenario:**
```
1. Traffic spikes, CPU goes to 85%
2. HPA scales up: 3 → 5 replicas (new pods pending)
3. Simultaneously, spot node is reclaimed
4. Karpenter tries to evict 1 pod (maxUnavailable: 1)
5. PDB allows it. Pod is evicted.
6. Pod reschedules to new node

Result:
- HPA: Desired 5, current 4 (1 pending new node), 1 in termination
- Effective capacity is LOWER during scale-up

This is OK as long as new pods start coming up.
```

**When maxUnavailable: 1 is WRONG:**

If cart service has 3 replicas and you can't afford ANY downtime:
```yaml
spec:
  minAvailable: 3  # Or equivalently, maxUnavailable: 0
```

But then:
```
Spot node reclaimed
Karpenter tries to evict pod
PDB says "no, must have 3 available"
Pod can't be evicted
Karpenter waits for replacement node to be Ready first
Then evicts and reschedules

Timing:
- Node reclaim warning: T+0s
- Replacement node launches: T+30s
- Replacement node Ready: T+50s
- Pod evicted and rescheduled: T+52s
- Original node terminates: T+120s
- Pod has been running on new node: 68 seconds
- Smooth transition!
```

**Better PDB Strategy:**

```yaml
kind: PodDisruptionBudget
metadata:
  name: cart
spec:
  minAvailable: 2  # Out of 3, keep 2 available
  # Allows 1 pod to be evicted, keeps 2 serving traffic
```

---

### A2.4 Topology Spread Constraints

**Typical Values:**

```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app: cart
- maxSkew: 2
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels:
      app: cart
```

**Explained:**
- **maxSkew: 1, topologyKey: zone**: Try to keep pod distribution across AZs perfectly balanced (max difference of 1 pod between any two AZs)
- **whenUnsatisfiable: DoNotSchedule**: If you can't satisfy the constraint, don't schedule the pod
- **maxSkew: 2, topologyKey: hostname**: Allow up to 2 pods on the same node (soft constraint, ScheduleAnyway if violated)

**Topology Spread + PDB Interaction:**

```
Scenario: 3 replicas across 3 AZs (us-west-2a, us-west-2b, us-west-2c)
- Pod-1 on node-A (us-west-2a)
- Pod-2 on node-B (us-west-2b)
- Pod-3 on node-C (us-west-2c)

Distribution: 1 pod per AZ (perfect, maxSkew satisfied)

Karpenter consolidation: AZ us-west-2a only has 1 node, so consolidate into AZ us-west-2b and us-west-2c

New allocation:
- Pod-1 needs to move (node-A is being terminated)
- New target: node-B (us-west-2b) or node-C (us-west-2c)
- Scheduler checks topology spread: us-west-2b now has 2 pods, us-west-2c has 1 pod
- maxSkew: 1 means max difference is 1 (2 - 1 = 1), satisfied
- Pod-1 scheduled to us-west-2c (balances to 2-1)
```

**When Topology Spread Fails:**

```
Scenario: 3 replicas, 3 AZs, but only 1 available node in us-west-2a

Topology spread says: "maxSkew: 1, so I need 1 pod in each AZ"
But only 1 node available in us-west-2a
Even if pod is scheduled there, 2 pods would be on us-west-2b

Result: Deadlock
- Scheduler can't schedule to satisfy constraint
- whenUnsatisfiable: DoNotSchedule → pod stays Pending

Fix: Change to whenUnsatisfiable: ScheduleAnyway (schedule even if constraint violated)
Or: Increase maxSkew to 2
Or: Remove one replica (2 replicas, 2 AZs works fine)
```

**Validation in Production:**

```bash
# Check topology spread on running pods
kubectl get pods -A -o custom-columns=NAME:.metadata.name,TOPOLOGY:.spec.topologySpreadConstraints[0].topologyKey

# Check actual distribution
kubectl get pods -o wide -l app=cart
# NAME          NODE                    ZONE
# cart-1        node-A (ip-10-0-1-x)    us-west-2a
# cart-2        node-B (ip-10-0-2-x)    us-west-2b
# cart-3        node-C (ip-10-0-3-x)    us-west-2c

# Verify distribution is balanced
kubectl get nodes --show-labels | grep topology.kubernetes.io/zone
```

---

### A2.5 Node Selection Complexity

**Why Use Both nodeSelector and nodeAffinity?**

```yaml
nodeSelector:
  role: spot-worker  # Hard requirement: MUST be on spot-worker nodes

affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
        - key: "node.kubernetes.io/lifecycle"
          operator: In
          values: ["spot"]  # Prefer spot, but On-Demand is OK
```

**The distinction:**
- **nodeSelector**: Mandatory. Pod won't schedule if no spot-worker nodes exist.
- **nodeAffinity**: Preferential. Pod schedules on On-Demand if necessary (less ideal but acceptable).

**Without nodeAffinity:**

```
Scenario: All spot-worker nodes are cordoned (being reclaimed)
No replacement nodes provisioned yet (in progress)
nodeSelector requires spot-worker, no nodes available
Pod: Pending

With nodeAffinity (weight: 100):
Pod can schedule to On-Demand nodes as fallback
Pod: Running (on more expensive node, but running)
When spot nodes come back, pod can reschedule
```

**Additional Resilience From nodeAffinity:**

```yaml
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    preference:
      matchExpressions:
      - key: "node.kubernetes.io/lifecycle"
        operator: In
        values: ["spot"]
  - weight: 50
    preference:
      matchExpressions:
      - key: "instance-type"
        operator: In
        values: ["m5.large", "m5.xlarge"]  # Prefer larger instances
```

**Scoring:**
- Spot node: weight 100 (best)
- Non-spot but large instance: weight 50
- Non-spot, small instance: weight 0

Scheduler picks the node with highest total weight.

**Production Recommendation:**

This two-layer approach is **excellent**:
1. **Layer 1 (nodeSelector)**: Ensures pod doesn't land on incompatible nodes (e.g., system nodes shouldn't run apps)
2. **Layer 2 (nodeAffinity)**: Optimizes placement for cost/performance

It's exactly what Netflix, Uber, and Airbnb use at scale.

---

## Round 3 Answers — Karpenter & Spot Management

### A3.1 Karpenter vs. Cluster Autoscaler - Latency Comparison

**How Karpenter Is Faster:**

**Cluster Autoscaler Flow** (old approach):
```
1. Pod is Pending (no nodes)
2. CA detects Pending pod (polls every 10s)
3. CA calculates required capacity
4. CA updates ASG desired_size from 3 to 4
5. ASG launches EC2 instance (20-40s)
6. Instance runs user-data script (10-20s)
7. Kubelet joins cluster (5-10s)
8. Pod scheduler notices new node
9. Pod scheduled and starts
Total: ~60-100 seconds, highly variable
```

**Karpenter Flow:**
```
1. Pod is Pending (no nodes)
2. Karpenter controller watches pod (immediate, webhook-driven)
3. Karpenter calculates required capacity
4. Karpenter calls EC2 RunInstances API (direct, not through ASG)
5. Instance launches (20-40s)
6. Kubelet joins cluster (5-10s)
7. Pod scheduled immediately
Total: ~30-50 seconds, more predictable
```

**Key Difference:**
- **CA**: Polling loop (10s detection lag) + ASG middleware
- **Karpenter**: Webhook-driven (immediate) + direct EC2 API

**Real-World Latency:**

AWS documentation + community benchmarks:
- **Cluster Autoscaler**: 2-3 minutes typical (worst case: 10+ minutes if ASG warm pool depleted)
- **Karpenter**: 30-90 seconds typical (worst case: 2 minutes if EC2 capacity exhausted)

**At scale (100 pods at once):**

**Cluster Autoscaler:**
```
CA sees 100 pending pods
CA calculates: "I need 50 new nodes"
CA updates ASG desired_size to 53
ASG launches 50 instances in parallel (AWS throttles to ~20/second)
First nodes ready in 30s, last nodes in 90s
Pods gradually schedule as nodes come online
```

**Karpenter:**
```
Karpenter sees 100 pending pods
Karpenter calculates: "I need 50 new nodes"
Karpenter groups pods by requirements (e.g., 50 pods need 256m CPU, 512Mi RAM)
Karpenter launches 5 x c5.large instances (right-sizing, not oversizing)
Pods bin-pack efficiently
Fewer nodes needed total
Faster overall (maybe 3-4 nodes instead of 5-6)
```

**The Batching Advantage:**

Karpenter uses EC2 `CreateFleet` API (bulk instance creation) not individual RunInstances calls. This is faster than sequential API calls.

---

### A3.2 Instance Type Diversity Strategy

**Why Not Just t3.medium?**

```
t3.medium characteristics:
- 2 vCPU, 4 GB RAM
- ~$0.0416/hour On-Demand
- ~$0.0125/hour Spot (70% discount)
```

**If you only use t3.medium:**

```
Spot market dynamic: AWS has 100 t3.medium instances available
Your cluster uses 5 t3.medium nodes
Suddenly, 90 of the 100 t3.medium instances are reclaimed (AWS needs capacity)
Your 5 nodes all receive interruption warnings simultaneously
All 5 nodes reclaimed at once
Entire cluster goes down
```

**With 10 instance types:**

```
Available capacity: 100 t3.medium, 80 m5.large, 60 m5a.large, ..., 10 c5.xlarge

Your cluster still needs 5 nodes (maybe 3x t3.medium + 2x m5.large)

AWS reclaims the 100 t3.medium instances
Your 3 t3.medium nodes are interrupted
But your 2 m5.large nodes are unaffected
Cluster is degraded (60% capacity) but not down

Meanwhile, Karpenter:
- Receives interruption warnings for 3 nodes
- Launches replacements
- Picks cheapest available (maybe c5.large is now cheaper than m5)
- Cluster recovers within 60 seconds
```

**Interruption Rate Data:**

AWS publishes interruption rates (from their spot data):
```
Single instance type: ~2-5% weekly interruption rate (1-2 nodes reclaimed per week)
Diverse fleet (10 types): ~0.2% weekly interruption rate (1 node reclaimed per 50 weeks)
```

At 5% rate, a 10-node cluster loses ~10 nodes/week (catastrophic).
At 0.2% rate, a 10-node cluster loses ~1 node/week (manageable).

**If All 10 Types Hit Capacity:**

```yaml
# karpenter.tf shows instance types
instance_types = [
  "t3.medium", "t3.large", "t3.xlarge",
  "t3a.medium", "t3a.large", "t3a.xlarge",
  "m5.large", "m5.xlarge",
  "m5a.large", "m5a.xlarge"
]
```

If all are capacity-limited:

```hcl
# Karpenter configuration has fallback
capacity_type = "on-demand"  # Falls back to On-Demand if spot unavailable
```

**Fallback behavior:**
1. Try all 10 spot types (in order of cost)
2. If all spot exhausted, try On-Demand t3/t3a types
3. If still no capacity, pod stays Pending

In production, AWS rarely exhausts ALL types simultaneously (happens during major regional events).

**How Karpenter Ranks and Picks:**

Karpenter uses AWS EC2 `DescribeInstanceTypeOfferings` API to get:
- Current spot price per instance type
- Availability per AZ per type

Algorithm (pseudo-code):
```
pending_pods = [pod1, pod2, ...]

for pod in pending_pods:
  required_resources = {cpu: 256m, memory: 512Mi}
  candidate_types = [types that fit required resources]
  
  # Rank by price
  candidate_types.sort_by(price_per_cpu_hour)
  
  # Pick cheapest available (prefer spot)
  for instance_type in candidate_types:
    if spot_available(instance_type):
      launch(instance_type, "SPOT")
      break
    elif on_demand_available(instance_type):
      launch(instance_type, "ON_DEMAND")
      break
```

**Result**: Pod gets cheapest available instance that fits its requirements.

---

### A3.3 Bin-Packing & Consolidation

**How Consolidation Decides Which Nodes:**

```
Current state:
- Node-A: 1 pod (256m CPU, 512Mi RAM) out of 4 CPUs available (25% utilized)
- Node-B: 2 pods (512m CPU, 1Gi RAM) out of 4 CPUs available (50% utilized)
- Node-C: 0 pods out of 4 CPUs (0% utilized, empty!)

Consolidation algorithm:
1. Identify candidates for removal (Node-A at 25%, Node-C at 0%)
2. Try to reschedule pods to other nodes
3. For Node-A: Move its 1 pod to Node-B (Node-B would have 768m CPU, 75% utilized)
   - Can Node-B fit the pod? Yes (has 2 CPUs available)
   - Consolidation: Remove Node-A
4. For Node-C: No pods to move, remove immediately
5. Result: Cluster shrinks from 3 nodes to 1 node
```

**Underutilization Threshold:**

Karpenter doesn't define a hard threshold like "nodes >50% utilized are safe." Instead, it:
- Simulates node removal
- Checks if all pods can reschedule
- If yes, removes the node

**If Consolidation Triggers During Traffic Spike:**

```
Normal traffic: 3 nodes
Peak traffic: Suddenly 1000 RPS
HPA triggers: Scale from 3 replicas to 10 replicas
New pods created: 7 pending

At the same time, consolidation is running:
- Consolidation tries to merge nodes
- But new pods are pending
- Consolidation stalls (can't remove nodes while pods are pending)
- Once new nodes provision, consolidation resumes

Result: Consolidation and scale-up both happen
No actual downtime, just more nodes temporarily
```

**Preventing Consolidation Thrashing:**

```
Scenario: Pod keeps getting evicted and rescheduled
- Node-A has pod
- Consolidation starts removing Node-A
- Pod gets evicted to Node-B
- Load on Node-B increases
- Consolidation triggered again
- Repeat
```

**Prevention:**
```hcl
# Karpenter controller configuration
consolidation:
  consolidate_after: "30s"  # Wait 30s after pod eviction before consolidating again
```

**Monitoring Consolidation:**

```bash
# Check Karpenter logs
kubectl logs -n karpenter deployment/karpenter -f

# Look for lines like:
# "consolidating 2 nodes, replacing with 1"
# "drifted nodes detected, replacing"

# Alert on consolidation frequency
kubectl get events -n karpenter | grep Consolidating
```

**Metrics to watch:**
- Number of nodes consolidated per hour
- Pod rescheduling frequency
- Node recycling rate

If consolidation runs every 5 minutes (very high), it might indicate:
- Traffic pattern is unstable (scale up/down constantly)
- Workload is poorly packed (pods too small/large)

---

### A3.4 Karpenter IRSA IAM Policy Analysis

**Why ec2:DescribeInstanceTypeOfferings Needs Resource: "*"?**

```hcl
{
  Sid    = "EC2Describe"
  Effect = "Allow"
  Action = [
    "ec2:DescribeInstanceTypeOfferings"  # THIS
  ]
  Resource = "*"
}
```

**AWS limitation**: EC2 Describe* actions don't support resource-level permissions. AWS requires `Resource: "*"` for:
- `DescribeInstances`
- `DescribeInstanceTypes`
- `DescribeAvailabilityZones`
- `DescribeSpotPriceHistory`

This is an AWS API limitation, not a Karpenter bug.

**Security implication**: If Karpenter credentials are compromised, attacker can call Describe on ANY instance in the account. But they can't:
- Terminate instances they don't own (TerminateInstances is scoped)
- Create instances in regions they don't have RunInstances for (RunInstances is scoped)

**If You Remove ec2:CreateTags:**

```
Karpenter launches an instance with EC2 RunInstances
But can't tag it with "karpenter.sh/nodepool=spot-worker"
Result:
- Instance launches
- Kubelet joins cluster
- But Karpenter doesn't recognize it as "owned by Karpenter"
- Karpenter tries to launch another node
- Duplicate nodes created
- Wasted cost
```

**ec2:CreateFleet vs. RunInstances:**

- **RunInstances**: Old API, launches individual instances sequentially
- **CreateFleet**: New AWS API (2017+), launches fleet of instances in parallel

**When Karpenter uses CreateFleet:**
- When launching 10+ instances at once
- Faster than sequential RunInstances
- More efficient

**Why the policy includes both:**
```hcl
"ec2:RunInstances",
"ec2:CreateFleet"
```

Older Karpenter versions used RunInstances. Newer versions prefer CreateFleet. Policy supports both for version compatibility.

**Is This Policy Least-Privilege?**

Not quite. Improvements:
```hcl
# Current (overly broad)
"ec2:RunInstances" on Resource "*"

# Better (scoped to launch templates Karpenter manages)
"ec2:RunInstances" on Resource "arn:aws:ec2:region:account:launch-template/karpenter-*"

# Even better (include condition)
"ec2:RunInstances" on Resource "*"
  Condition {
    StringEquals {
      "ec2:ResourceTag/created-by" = "karpenter"
    }
  }
```

But this requires:
1. Karpenter to tag all resources
2. Regular audits to ensure proper tagging
3. More complex IAM policy management

For most production deployments, the current policy is acceptable:
- Karpenter is a trusted system component
- It runs on dedicated on-demand nodes
- If compromised, other problems exist already

---

### A3.5 SQS Queue Visibility Timeout Issue

**If Karpenter Takes >60s to Process:**

```
Time 0: SQS queue receives spot interruption message
Time 0: Karpenter polls queue, receives message
Time 20: Karpenter starts processing (cordon node)
Time 60: visibility_timeout expires
Time 60: SQS makes message visible again (other consumers see it)
Time 65: Karpenter finishes processing (node already drained)
Time 70: Different process polls queue, sees SAME message
Time 70: Duplicate processing (another node gets cordoned)
```

**Result**: Same node might be cordoned twice, or different nodes cordoned unintentionally.

**In reality, Karpenter's processing is fast:**
- Cordon: 1-2s
- Drain: 10-30s (depends on pod count)
- Total: 20-40s (well under 60s)

**But if there's a delay (network issue, high load):**

```bash
# Monitor SQS metrics
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-west-2.amazonaws.com/123456789/retail-store-spot-termination \
  --attribute-names ApproximateNumberOfMessagesDelayed

# Check for messages getting reprocessed
# Look for duplicate interruption events in Karpenter logs
```

**Better configuration:**

```hcl
visibility_timeout_seconds = 120  # Karpenter has 2 minutes
```

This gives Karpenter more time without risk. The cost is low (messages stay invisible for 2 minutes instead of 1 minute, but events are time-critical anyway).

**Even better: Configure Karpenter to acknowledge messages:**

```hcl
# Karpenter should delete message from queue after processing
# This prevents reprocessing even if visibility_timeout is short
```

Most modern queue-based systems do this (SQS best practice).

---

## Round 4 Answers — Terraform Infrastructure as Code

### A4.1 Terraform State Corruption Recovery

**Detecting Corruption:**

```bash
# Corruption symptoms
terraform plan
# Error: resource XXX: invalid JSON: unexpected token

terraform validate
# Fails silently (validate doesn't check state)

# Explicit check
terraform state list
# Error: state file cannot be parsed

# Inspect state file directly
cat terraform.tfstate | jq . 
# Error: invalid JSON
```

**Recovery Strategy:**

**Step 1: Backup & Document Current State**

```bash
# Save the corrupted state
cp terraform.tfstate terraform.tfstate.corrupted

# Document what's in AWS right now
aws eks describe-cluster --name retail-store > aws_reality.json
aws ec2 describe-instances > instances.json
```

**Step 2: Identify Lost Data**

```bash
# What does state think exists?
terraform state list > state_resources.txt

# What actually exists in AWS?
# (Compare manually or write script)

# Typical corruption scenario:
# - VPC is in state and in AWS (OK)
# - EKS cluster is in state but NOT in AWS (corrupted)
# - RDS is NOT in state but IS in AWS (missed)
```

**Step 3: Decide on Recovery Path**

**Option A: Terraform-managed recovery** (if Kubernetes resources not affected)
```bash
# Remove corrupted resources from state (don't destroy in AWS)
terraform state rm module.retail_app_eks

# Re-import them
terraform import module.retail_app_eks.aws_eks_cluster retail-store-xxx

# Apply should be no-op now
terraform plan  # Should show no changes
```

**Option B: Destroy & Rebuild** (risky, careful!)
```bash
# If state is too corrupted to fix
# WARNING: This WILL delete AWS resources

# First, plan to see what would be destroyed
terraform plan -destroy

# Only proceed if you're sure
terraform destroy -auto-approve

# Then reapply
terraform apply
```

**But this causes:**
- Data loss (if databases/storage still pointed by state)
- Downtime (cluster is gone during recreation)
- ArgoCD loss (if applications were deployed)

**Option C: Rebuild from scratch in new state** (safest)
```bash
# Create new state file for same infrastructure
terraform workspace new prod_recover

# Apply to create parallel cluster
terraform apply

# Once verified, migrate traffic
# Then destroy old state/cluster

# Finally, merge workspaces
terraform workspace select default
terraform workspace delete prod_recover
```

**If Kubernetes Resources Were Affected:**

```bash
# Did you lose pod data?
# Check if persistent volumes still exist

aws ec2 describe-volumes | grep retail-store

# Did you lose ConfigMaps/Secrets?
# They're stored in etcd (EKS managed), should be fine

kubectl get configmaps -A
kubectl get secrets -A

# If these are accessible, workloads can restart normally
```

**Automation: Terraform State Backup**

```bash
# Don't rely on manual backups
# Use Terraform Cloud/Enterprise (automatic state versioning)
# Or S3 backend with versioning enabled

terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

# Configure S3 versioning
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  
  versioning_configuration {
    status = "Enabled"
  }
}
```

**Then recovery is:**
```bash
# List state file versions
aws s3api list-object-versions --bucket my-terraform-state

# Restore from specific version
aws s3api get-object \
  --bucket my-terraform-state \
  --key prod/terraform.tfstate \
  --version-id abc123 \
  terraform.tfstate
```

---

### A4.2 Terraform Module Versioning

**What Does ~> 20.24 Mean?**

```
~> 20.24 is "pessimistic constraint"

Allows: >= 20.24 and < 21.0
✓ 20.24 (exact)
✓ 20.25 (patch update)
✓ 20.99 (minor update within major)
✗ 21.0 (major version jump)
✗ 20.23 (too old)
```

**Breaking Changes Within Range:**

EKS module v20.x to v21.x (from UPGRADE-21.0.md):
```
Major breaking changes:
- Variable names changed (cluster_name → name)
- Node group defaults changed (ami_type, IMDS, etc.)
- Removed aws-auth sub-module
- Removed some variables entirely (elastic_gpu_specifications)
```

Even within v20.x, patch updates can break configurations:
```hcl
# v20.0 uses aws_eks_cluster (old API)
# v20.24 uses aws_eks_cluster with new API

# Your code might expect old output names that no longer exist
# Unlikely but possible within minor versions
```

**Testing Minor Version Upgrades:**

```bash
# 1. In development environment
cd terraform/dev

# 2. Update module version
sed -i 's/version = "~> 20.24"/version = "~> 20.25"/' main.tf

# 3. Plan without applying
terraform plan > upgrade_plan.txt

# 4. Review changes carefully
cat upgrade_plan.txt | grep -E "^(~|+|-|#)" 

# Expected: No resource destruction/replacement (should be ~)
# Unexpected: If any resources marked for replacement (-/+), rollback

# 5. Apply to test cluster
terraform apply

# 6. Validate tests pass
cd ../tests && pytest test_cluster.py --cluster-name retail-store-dev

# 7. If all good, apply to prod
cd ../prod
sed -i 's/version = "~> 20.24"/version = "~> 20.25"/' main.tf
terraform plan
terraform apply
```

**Migrating from v20 to v21:**

From UPGRADE-21.0.md:
```hcl
# BEFORE (v20.x)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name  # ← v20 name
  cluster_version = var.kubernetes_version  # ← v20 name
```

```hcl
# AFTER (v21.x)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name              = local.cluster_name  # ← v21 renamed from cluster_name
  kubernetes_version = var.kubernetes_version  # ← v21 renamed from cluster_version
```

**Automation:**

```bash
#!/bin/bash
# Script to help with EKS v20 → v21 migration

# 1. Backup
cp terraform.tfstate terraform.tfstate.v20

# 2. Update version
sed -i 's/version = "~> 20/version = "~> 21/' main.tf

# 3. Update variable names (example)
sed -i 's/cluster_name =/name =/' main.tf
sed -i 's/cluster_version =/kubernetes_version =/' main.tf

# 4. Validate
terraform validate

# 5. Plan (review!)
terraform plan -out=upgrade.tfplan

# 6. Show only replacements (dangerous)
terraform show upgrade.tfplan | grep -E "must be replaced"

# If no replacements expected, apply
terraform apply upgrade.tfplan
```

---

### A4.3 VPC Subnet CIDR Computation

**With vpc_cidr = "10.0.0.0/16":**

```hcl
private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 10)]
public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k)]
```

**cidrsubnet() function:**
```
cidrsubnet(base, newbits, netnum)
- base: "10.0.0.0/16"
- newbits: 8 (split /16 into /24, adds 8 bits to mask)
- netnum: The network number within the /8 space

Result:
/16 gives 256 /24 networks (2^8)
cidrsubnet("10.0.0.0/16", 8, 0) = "10.0.0.0/24" (netnum 0)
cidrsubnet("10.0.0.0/16", 8, 1) = "10.0.1.0/24" (netnum 1)
...
cidrsubnet("10.0.0.0/16", 8, 255) = "10.0.255.0/24" (netnum 255)
```

**For 3 AZs (us-west-2a, us-west-2b, us-west-2c):**

```
local.azs = ["us-west-2a", "us-west-2b", "us-west-2c"]

public_subnets:
- k=0, netnum=0:   cidrsubnet("10.0.0.0/16", 8, 0)   = "10.0.0.0/24"
- k=1, netnum=1:   cidrsubnet("10.0.0.0/16", 8, 1)   = "10.0.1.0/24"
- k=2, netnum=2:   cidrsubnet("10.0.0.0/16", 8, 2)   = "10.0.2.0/24"
Result: ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]

private_subnets:
- k=0, netnum=0+10=10:  cidrsubnet("10.0.0.0/16", 8, 10)  = "10.0.10.0/24"
- k=1, netnum=1+10=11:  cidrsubnet("10.0.0.0/16", 8, 11)  = "10.0.11.0/24"
- k=2, netnum=2+10=12:  cidrsubnet("10.0.0.0/16", 8, 12)  = "10.0.12.0/24"
Result: ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
```

**Why Start Private at Offset 10?**

To avoid overlap:
- Public uses 0-2 (netnum k)
- Private uses 10-12 (netnum k + 10)
- Leaves 3-9 and 13-255 for future expansion

This gives:
- 3 public subnets (3 IPs each)
- 3 private subnets (253 IPs each)
- 242 additional subnets available for future use

**If You Add 4 AZs:**

```hcl
local.azs = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]

public_subnets:
- 0: "10.0.0.0/24"
- 1: "10.0.1.0/24"
- 2: "10.0.2.0/24"
- 3: "10.0.3.0/24"  ← Works fine

private_subnets:
- 10: "10.0.10.0/24"
- 11: "10.0.11.0/24"
- 12: "10.0.12.0/24"
- 13: "10.0.13.0/24"  ← Works fine
```

**Result**: Yes, logic scales correctly to 4, 5, even 10 AZs (as long as public offset + count < 10).

**Edge Case: What If You Have 10+ AZs?**

```hcl
# Not realistic for most AWS regions, but possible in theoretical setup
local.azs = [for i in range(10) : "us-west-2${chr(97+i)}"]
# Result: az0, az1, ..., az9

public_subnets:
- 0: "10.0.0.0/24"
- ...
- 9: "10.0.9.0/24"  ← OK

private_subnets:
- 10: "10.0.10.0/24"
- ...
- 19: "10.0.19.0/24"  ← Overlap! Public az9 is 10.0.9.0, private az9 is 10.0.19.0 (overlapping!)
```

**Wait, not actually overlapping:**
```
Public: 10.0.0.0 - 10.0.9.0 (netnum 0-9)
Private: 10.0.10.0 - 10.0.19.0 (netnum 10-19)
No overlap!
```

**This logic is robust for 3-20 AZs without modification.**

---

### A4.4 Managing Default Resources

**Why Manage Defaults?**

Normally, AWS creates default VPC resources automatically:
- Default Network ACL
- Default Route Table
- Default Security Group

**Without managing them, Terraform doesn't control them:**

```hcl
# Without manage_default_network_acl = true
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}
# AWS creates default NACL automatically
# Terraform has no reference to it
# If you manually modify default NACL, Terraform won't know
```

**With managing them:**

```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Terraform takes over the default NACL
resource "aws_network_acl" "default" {
  vpc_id = aws_vpc.main.id
  
  # This is the DEFAULT NACL, explicitly managed
  default = true
  
  tags = {Name = "${var.cluster_name}-default-nacl"}
}
```

**Now Terraform controls the default NACL:**
- Any manual changes to default NACL are detected as drift
- `terraform plan` shows them
- `terraform destroy` removes custom tags/rules from default NACL

**Benefits:**
1. **Consistent tagging**: All resources tagged consistently (for cost allocation)
2. **Drift detection**: `terraform plan` catches manual changes
3. **Explicit configuration**: Default resources are clear in code

**Risks:**
1. **Shared accounts**: If another team uses the same VPC, managing defaults affects them
2. **Destructive operations**: `terraform destroy` modifies shared resources
3. **Permission issues**: Requires IAM permissions to modify default resources

**In Shared AWS Account:**

```hcl
# Not recommended
manage_default_network_acl    = false  # Let AWS manage
manage_default_route_table    = false
manage_default_security_group = false
```

**In Dedicated AWS Account:**

```hcl
# Recommended (what this project does)
manage_default_network_acl    = true  # Terraform controls
manage_default_route_table    = true
manage_default_security_group = true
```

---

### A4.5 Terraform Validation & Testing

**Missing Validations:**

```hcl
# Current: Only environment is validated
variable "environment" {
  validation {
    condition = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Only dev, staging, prod allowed"
  }
}

# Missing validations:
```

**Add These:**

```hcl
# 1. Spot node sizing
variable "spot_min_size" {
  validation {
    condition = var.spot_min_size >= 0 && var.spot_max_size >= var.spot_min_size
    error_message = "spot_min_size must be >= 0 and <= spot_max_size"
  }
}

# 2. Kubernetes version format
variable "kubernetes_version" {
  validation {
    condition = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "Kubernetes version must be like '1.35'"
  }
}

# 3. VPC CIDR is valid
variable "vpc_cidr" {
  validation {
    condition = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be valid CIDR notation"
  }
}

# 4. Production constraints
variable "enable_single_nat_gateway" {
  validation {
    condition = var.environment != "prod" || var.enable_single_nat_gateway == false
    error_message = "Production must use multiple NAT gateways (enable_single_nat_gateway = false)"
  }
}
```

**Terraform Validation vs. Checkov:**

- **Terraform validation**: Block invalid inputs before apply
- **Checkov**: Policy-as-code, detects infrastructure misconfigurations

Example:
```bash
# Terraform validation catches
terraform apply -var='spot_max_size=2' -var='spot_min_size=5'
# Error: spot_min_size must be <= spot_max_size

# Checkov catches
checkov -d terraform/
# Check: Ensure single NAT gateway not used in production
# Check: Ensure encryption at rest enabled on databases
# Check: Ensure public access is limited to HTTPS
```

**For Production:**

```bash
# 1. Use Terraform validation for basic constraints
# 2. Use Checkov for security/compliance policies
# 3. Use Terratest for integration testing

# Terratest example:
```go
func TestEKSCluster(t *testing.T) {
  options := &terraform.Options{
    TerraformDir: "../",
    Vars: map[string]interface{}{
      "environment": "test",
    },
  }
  
  defer terraform.Destroy(t, options)
  terraform.InitAndApply(t, options)
  
  // Validate the cluster exists
  clusterName := terraform.Output(t, options, "cluster_name")
  cluster := eks.GetCluster(t, "us-west-2", clusterName)
  assert.NotNil(t, cluster)
  assert.Equal(t, "1.35", cluster.Version)
}
```

---

## Round 5 Answers — CI/CD & GitOps

### A5.1 ArgoCD Sync Policy Risks

**prune: true Consequences:**

```yaml
syncPolicy:
  automated:
    prune: true  # Delete resources not in Git
```

**Scenario:**

```
1. Git repo has: cart deployment with 3 replicas
2. ArgoCD syncs → cart deployment created
3. Operator manually scales to 5 replicas (using kubectl)
4. ArgoCD detects drift (5 replicas in cluster, 3 in Git)
5. ArgoCD prunes the 2 extra replicas
6. Deployment back to 3 replicas
```

**Risk: Accidental Deletion**

```
1. Development creates temporary PVC for debugging
2. Adds it to namespace but NOT to Git
3. ArgoCD sync with prune: true
4. PVC is deleted (not in Git)
5. Data loss if pod was using it
```

**When Prune is DANGEROUS:**

- Mixed management (some resources via ArgoCD, others manual) → lost data
- Secrets created outside Git (AWS credentials, TLS certs) → deleted
- Test resources left in cluster → silently purged

**Mitigation:**

```yaml
syncPolicy:
  automated:
    prune: false  # Disable auto-prune
  syncOptions:
    - PrunePropagationPolicy=background  # Manual prune is slower, safer
```

Or use granular control:
```yaml
syncPolicy:
  automated:
    prune: true
  syncOptions:
    - PrunePropagationPolicy=foreground  # Safer: waits for resource deletion
    - Validate=false  # Don't validate if not in schema
```

---

### A5.2 ArgoCD Sync Waves Deep Dive

**Wave Ordering Rules:**

```yaml
# Wave execution order:
# Wave 0 → Wave 1 → Wave 2 → ...

# Correct order for microservices:
kind: Application
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # First
spec:
  source:
    path: manifests/namespace
---
# Namespace created first ↓

kind: Application
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Second
spec:
  source:
    path: manifests/secrets
---
# Secrets created second ↓

kind: Application
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"  # Third
spec:
  source:
    path: manifests/deployments
---
# Deployments created third ↓

kind: Application
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"  # Fourth
spec:
  source:
    path: manifests/ingress
```

**Why This Order:**

1. **Wave 0 (Namespace)**: Must exist before anything else
2. **Wave 1 (Secrets)**: Must exist before pods reference them
3. **Wave 2 (Deployments)**: Pods need secrets to start
4. **Wave 3 (Ingress)**: Routes traffic to existing services

**Negative Waves:**

```yaml
# Wave -1 executes before Wave 0
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

Use case: If namespace needs to wait for something:
```yaml
# Wave -1: Create RBAC role (prerequisite)
kind: ClusterRole
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
---
# Wave 0: Create namespace (uses the role)
kind: Namespace
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

**Circular Dependency Problem:**

```
Wave 1: Create cart service (depends on catalog)
Wave 2: Create catalog service (depends on cart)
Result: Both wait for each other indefinitely
```

**Solution:**

```yaml
# Cart doesn't need catalog to START
# Cart only needs catalog's SERVICE ENDPOINT to work

kind: Deployment
metadata:
  name: cart
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  containers:
  - name: cart
    env:
    - name: CATALOG_URL
      value: "http://catalog:8080"  # Service name (DNS)
---
# Catalog in same wave or later
kind: Deployment
metadata:
  name: catalog
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```

**Works because:**
- Cart pod starts, tries to connect to http://catalog:8080
- Catalog pod also starting
- Cart retries (with backoff)
- Catalog pod becomes Ready
- Cart succeeds on next retry

**Better pattern: Service depends on Deployment**

If cart MUST wait for catalog:
```yaml
# Wave 1: Create all services (service is lighter than deployment)
kind: Service
metadata:
  name: cart
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
kind: Service
metadata:
  name: catalog
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
# Wave 2: Create all deployments
kind: Deployment
metadata:
  name: cart
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  # Liveness probe fails until catalog is ready
  livenessProbe:
    httpGet:
      path: /health
      port: 8080
    initialDelaySeconds: 10
    periodSeconds: 5
---
kind: Deployment
metadata:
  name: catalog
  annotations:
    argocd.argoproj.io/sync-wave: "2"
```

---

### A5.3 chart/ vs. charts/ Directory

**The Double Directory Pattern:**

In the project structure:
```
src/cart/
├── chart/           ← ?
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── charts/          ← ?
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
```

**Most likely explanation: Migration/Versioning**

```
Old: charts/ (original Helm chart)
New: chart/ (new/refactored chart, v2)
```

During migration:
- New code deploys from chart/
- Old deployments still reference charts/
- Gradual migration over time

**Or: Different Deployment Modes**

```
charts/: Full-featured chart (all services enabled)
chart/: Minimal chart (just this service)
```

**Or: Stateless vs. Stateful**

In values.yaml comments:
```yaml
# values-stateful.yaml exists!
```

This suggests:
- chart/values.yaml: Stateless variant (pods can be evicted)
- chart/values-stateful.yaml: Stateful variant (persistent storage needed)

**Better Investigation:**

```bash
# Compare the two directories
diff -r src/cart/chart src/cart/charts

# Check Git history
git log --follow src/cart/chart
git log --follow src/cart/charts

# Check ArgoCD application
kubectl get application retail-store-cart -o yaml | grep path
# path: src/cart/chart  ← This one is actually used
```

**Most Likely**: The charts/ directory is **legacy** and **should be deleted**. The chart/ directory is the current source of truth.

**In Production Code Review:**

"I see two identical Helm chart directories. Which one should developers modify? Which one is deployed? Can we delete the old one to reduce confusion?"

---

### A5.4 GitOps Deployment Flow

**Complete Flow:**

```
1. Developer commits new code
   $ git push origin feature-branch
   $ git commit -m "Add color preference to cart"

2. CI/CD Pipeline Triggered
   GitHub webhook → GitHub Actions (or Jenkins)
   
3. Tests Run
   - Unit tests
   - Integration tests
   - Security scan (Trivy, SonarQube)
   
4. Docker Image Built & Pushed
   docker build -t 123456789.dkr.ecr.us-west-2.amazonaws.com/cart:v1.2.3 .
   docker push ...
   
5. Helm values.yaml Updated
   sed -i 's/tag: v1.2.2/tag: v1.2.3/' src/cart/chart/values.yaml
   git commit -m "Update cart image to v1.2.3"
   git push origin main
   
6. ArgoCD Detects Change
   Two methods:
   a) Webhook (fast): GitHub sends "main branch updated" → ArgoCD polls Git
   b) Polling (slow): ArgoCD polls Git every 3-5 minutes
   
   ArgoCD polls: git clone https://github.com/...
   ArgoCD detects: values.yaml changed
   
7. ArgoCD Syncs Application
   - Renders Helm template with new image tag
   - Applies manifests to cluster
   - kubectl apply -f rendered-manifests/
   
8. Kubernetes Scheduler Detects Deployment Change
   - Old pods: cart:v1.2.2
   - New pods: cart:v1.2.3
   - Scheduler rolls out new pods (respects PDB, topology spread)
   
9. Pods Start
   - Image pulled from ECR
   - Container starts
   - Readiness probe checks health
   - Once healthy, receives traffic
```

**Detection Latency:**

- Webhook: <5 seconds (GitHub sends event immediately)
- Polling: 3-5 minutes (ArgoCD checks Git every 3-5 min by default)

**Real-World Example:**

```bash
# Time 10:00:00 — Developer pushes
$ git push origin main

# Time 10:00:03 — GitHub webhook fires
# Logs: "Webhook received for retail-store-cart application"

# Time 10:00:05 — ArgoCD syncs
$ argocd app sync retail-store-cart
# Output: "Synced 5 resources"

# Time 10:00:10 — Old pods terminate, new pods start
$ kubectl rollout status deployment/cart
# Output: "deployment "cart" successfully rolled out"

# Time 10:00:25 — New pods are healthy and serving traffic
$ kubectl get pods
# cart-new-84f6d9 Running
# cart-old-7c2b4a Terminating
```

**To Verify Sync Status:**

```bash
kubectl get application retail-store-cart -o yaml | grep status

# Or
argocd app get retail-store-cart
# Sync Status: Synced
# Sync OperationState: Succeeded
```

---

### A5.5 Helm Template Error Handling

**Syntax Error in Template:**

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.foo.bar.baz }}  # ERROR: baz doesn't exist
```

**What Happens:**

```bash
# Helm template rendering
helm template retail-store-cart src/cart/chart/

# Output:
Error: template: carts/templates/deployment.yaml:4:24:
executing "carts/templates/deployment.yaml" at <.Values.foo.bar.baz>:
can't evaluate field baz in type map[string]interface {}

# Rendering FAILS
```

**ArgoCD Behavior:**

```yaml
kind: Application
metadata:
  name: retail-store-cart
status:
  conditions:
  - lastTransitionTime: "2024-05-12T10:00:00Z"
    message: "Helm template rendering failed"
    type: SyncFailed
  operationState:
    finalized: true
    phase: Failed
```

**Result**: Application shows as **OutOfSync** with error message. **No changes applied.**

**Catching This in CI/CD:**

```bash
#!/bin/bash
# ci/helm-validate.sh

for chart in src/*/chart; do
  echo "Validating $chart..."
  
  # 1. Syntax check
  helm lint "$chart"
  
  # 2. Template rendering dry-run
  helm template retail-store "$chart" -f "$chart/values.yaml" > /dev/null
  if [ $? -ne 0 ]; then
    echo "ERROR: Helm template rendering failed"
    exit 1
  fi
  
  # 3. Validate YAML syntax
  helm template retail-store "$chart" | kubectl apply -f - --dry-run=client
  if [ $? -ne 0 ]; then
    echo "ERROR: Generated YAML is invalid"
    exit 1
  fi
done

echo "All charts validated successfully"
```

**GitHub Actions Example:**

```yaml
# .github/workflows/helm-validate.yml
name: Helm Validation

on:
  pull_request:
    paths:
      - 'src/*/chart/**'
      - '.github/workflows/helm-validate.yml'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    
    - uses: azure/setup-helm@v3
    
    - name: Validate Helm Charts
      run: |
        for chart in src/*/chart; do
          helm lint "$chart"
          helm template test "$chart" | kubectl apply -f - --dry-run=client
        done
```

**Then, template errors are caught BEFORE merge**, not after ArgoCD deployment.

---

## Round 6 Answers — Security & RBAC

### A6.1 Pod Security & Dockerfile Hardening

**Precedence: Dockerfile vs. Helm**

```dockerfile
# Dockerfile
USER appuser
```

```yaml
# Helm values.yaml
securityContext:
  runAsUser: 1000  # This is the SAME user ID
```

**When pod starts:**
1. Docker image sets USER appuser (UID 1000)
2. Helm securityContext also sets runAsUser: 1000
3. **Result**: Both agree, no conflict

**If they disagreed:**
```dockerfile
USER root
```

```yaml
securityContext:
  runAsUser: 1000
  runAsNonRoot: true
```

Kubernetes would **enforce** RunAsUser: 1000, overriding the Dockerfile USER root.

**The read-only root filesystem risk:**

```yaml
readOnlyRootFilesystem: true
```

**What breaks with read-only root:**

```
Java heap dumps: java writes to /var/crash → Permission denied
Java temp files: java writes to /var/tmp → Permission denied
Spring Boot logs: writes to /var/log → Permission denied
```

**Solution: Mount writable volumes:**

```yaml
volumeMounts:
- name: tmp
  mountPath: /tmp
- name: heap-dumps
  mountPath: /var/crash
- name: logs
  mountPath: /var/log
volumes:
- name: tmp
  emptyDir:
    medium: Memory  # RAM-backed (faster, lost on pod restart)
    sizeLimit: 256Mi
- name: heap-dumps
  emptyDir:
    sizeLimit: 1Gi  # Disk-backed
- name: logs
  emptyDir:
    sizeLimit: 256Mi
```

**Templated in Helm:**

```yaml
# templates/deployment.yaml
volumeMounts:
{{- if .Values.securityContext.readOnlyRootFilesystem }}
- name: tmp
  mountPath: /tmp
- name: logs
  mountPath: /var/log
{{- end }}

volumes:
{{- if .Values.securityContext.readOnlyRootFilesystem }}
- name: tmp
  emptyDir:
    medium: Memory
    sizeLimit: 256Mi
- name: logs
  emptyDir:
    sizeLimit: 256Mi
{{- end }}
```

**Should You Use seccomp Too?**

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
    # type: Localhost
    # localhostProfile: "my-profile.json"
```

**RuntimeDefault**: Uses Docker default seccomp profile (blocks ~100 dangerous syscalls)

**Custom seccomp profile**: Define exact syscalls allowed

**For Java apps:**
```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "archMap": [
    {
      "architecture": "SCMP_ARCH_X86_64",
      "subArchitectures": ["SCMP_ARCH_X86", "SCMP_ARCH_X32"]
    }
  ],
  "syscalls": [
    {
      "names": ["socket", "bind", "listen", "connect", "accept", ...],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["open", "openat", "read", "write", "close", ...],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Java needs many syscalls (signal handling, memory mapping, thread creation). Custom seccomp is complex; RuntimeDefault is usually enough.

---

### A6.2 IRSA & Compromised Pod Attack Surface

**Attack Scenario:**

```
1. Malicious pod starts on cluster
2. Pod reads /var/run/secrets/kubernetes.io/serviceaccount/token
3. This token is the Karpenter service account JWT
4. Pod assumes the Karpenter IAM role using OIDC federation
5. Pod now has Karpenter permissions (EC2 RunInstances, etc.)
6. Pod launches malicious EC2 instances in attacker's account
```

**How OIDC Federation Works:**

```
Step 1: Pod gets Karpenter service account token (auto-mounted)
$ cat /var/run/secrets/kubernetes.io/serviceaccount/token
eyJhbGciOiJIUzI1NiIsImtpZCI6ImtzeS05OHpxIn0.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50IiwibmFtZXNwYWNlIjoia3ViZS1zeXN0ZW0iLCJzZXJ2aWNlYWNjb3VudC5uYW1lIjoia2FycGVudGVyIiwic2VydmljZWFjY291bnQudWlkIjoiMTIzNDU2In0.aBcDeF...

Step 2: Pod calls AWS STS AssumeRoleWithWebIdentity
aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::123456789:role/karpenter \
  --role-session-name karpenter-session \
  --web-identity-token eyJhbGc...

Step 3: AWS verifies JWT signature using Kubernetes OIDC provider
AWS calls: https://oidc.eks.us-west-2.amazonaws.com/id/EXAMPLEID/.well-known/openid-configuration

Step 4: If JWT is valid, AWS returns temporary credentials
{
  "Credentials": {
    "AccessKeyId": "ASIAJ2...",
    "SecretAccessKey": "abc123...",
    "SessionToken": "AQoD..."
  }
}

Step 5: Pod now has Karpenter IAM credentials
```

**Detection:**

```bash
# Monitor AWS CloudTrail for unexpected AssumeRoleWithWebIdentity calls
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity

# Alert if from non-Karpenter pod
# (CloudTrail logs UserAgent field with pod name, if configured correctly)
```

**Mitigation:**

```hcl
# 1. Restrict Karpenter IRSA to specific namespace/service account
module "karpenter_irsa" {
  oidc_providers = {
    main = {
      provider_arn               = module.retail_app_eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]  # Explicit namespace
    }
  }
}

# 2. Network policy to prevent pods from reaching AWS metadata service
# (But Kubernetes pods need to call AWS APIs, so this is limited)

# 3. Pod Security Policy to prevent:
#    - Privileged containers
#    - Host network access
#    - Service account token auto-mounting (if not needed)

# 4. Pod Security Standards (PodSecurityPolicy replacement)
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: restricted
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'configMap'
    - 'emptyDir'
    - 'projected'
    - 'secret'
    - 'downwardAPI'
    - 'persistentVolumeClaim'
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'MustRunAs'
  supplementalGroups:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
  readOnlyRootFilesystem: true
```

**Better Approach: Pod Security Standards (k8s 1.25+)**

```bash
# Apply to namespace
kubectl label namespace karpenter pod-security.kubernetes.io/enforce=restricted
kubectl label namespace karpenter pod-security.kubernetes.io/audit=restricted

# Now any pod in karpenter namespace must meet restricted pod security standards
# If pod violates standards, it won't run
```

---

### A6.3 Network Policies - Missing

**Why No NetworkPolicy Manifests:**

You're right to notice this gap. Without NetworkPolicy, the cluster has:
- No egress restrictions (pods can reach any IP/port)
- No ingress restrictions (any pod can talk to any other pod)

**Default Behavior (No NetworkPolicy):**

```
cart-pod → can reach → catalog-pod ✓
cart-pod → can reach → prometheus-pod ✓
cart-pod → can reach → karpenter-pod ✓
cart-pod → can reach → ANY external IP ✓
```

**With NetworkPolicy (recommended):**

```yaml
# Default deny all ingress
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}  # Matches all pods
  policyTypes:
  - Ingress
  # No ingress rules specified = deny all

---
# Allow cart ingress from Traefik only
kind: NetworkPolicy
metadata:
  name: allow-cart-ingress
spec:
  podSelector:
    matchLabels:
      app: cart
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: traefik
    ports:
    - protocol: TCP
      port: 8080

---
# Allow cart egress to catalog only
kind: NetworkPolicy
metadata:
  name: allow-cart-egress
spec:
  podSelector:
    matchLabels:
      app: cart
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: catalog
    ports:
    - protocol: TCP
      port: 8080
  # Allow DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
  # Allow HTTPS to external (for AWS API calls)
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443
```

**Should This Be Implemented?**

**Yes, eventually.** But:
- Requires understanding of all service-to-service communication
- Easy to break if policy is too restrictive
- Requires testing before production

**Recommendation for this project:**

```bash
# Phase 1: Add default-deny NetworkPolicy to non-critical namespaces
kubectl apply -f network-policies/default-deny.yaml -n retail-store

# Phase 2: Monitor what breaks (kubectl get events -n retail-store)

# Phase 3: Add allow rules incrementally
# For each error "pod X cannot reach pod Y", add NetworkPolicy

# Phase 4: Production lockdown
# Apply to all namespaces, only allow necessary traffic
```

---

### A6.4 Secret Management - Major Gap

**Current Approach (Risky):**

```yaml
imagePullSecrets:
  - name: regcred  # Where's this secret?
```

**The regcred is likely:**
- Stored in GitHub in plaintext (catastrophic)
- Or created manually in cluster (not GitOps-friendly)
- Or injected by CI/CD at deploy time (risky)

**Solutions:**

**Option 1: Sealed Secrets**

```bash
# Install sealed secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/sealed-secrets-0.24.0.yaml

# Create secret normally (locally)
kubectl create secret docker-registry regcred \
  --docker-server=123456789.dkr.ecr.us-west-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password=... \
  -n retail-store --dry-run=client -o yaml > secret.yaml

# Seal it
kubeseal -f secret.yaml -w sealed-secret.yaml

# Now sealed-secret.yaml is safe to commit to Git
# Only the cluster can unseal it (has private key)
git add sealed-secret.yaml
```

**Option 2: External Secrets Operator (ESO)**

```yaml
# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system --create-namespace

---
# Use AWS Secrets Manager
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-store
  namespace: retail-store
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-west-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa

---
# Reference secret from AWS Secrets Manager
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: regcred
  namespace: retail-store
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-store
    kind: SecretStore
  target:
    name: regcred
    template:
      type: kubernetes.io/dockercfg
      data:
        .dockercfg: |
          {
            "123456789.dkr.ecr.us-west-2.amazonaws.com": {
              "auth": "{{ .token | b64enc }}"
            }
          }
  data:
  - secretKey: token
    remoteRef:
      key: ecr-auth-token
```

**Option 3: IRSA for ECR Pull**

```yaml
# Don't use imagePullSecrets at all
# Use ECR IAM permissions instead

# 1. Create IAM role for the pod
# 2. Pod assumes role via IRSA
# 3. Pod has AmazonEC2ContainerRegistryReadOnly permissions
# 4. Pod can pull images without credentials

apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: retail-store
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/app-ecr-pull

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart
spec:
  template:
    spec:
      serviceAccountName: app-sa  # Uses IRSA role
      # No imagePullSecrets needed!
      containers:
      - image: 123456789.dkr.ecr.us-west-2.amazonaws.com/cart:latest
```

**Recommended: Option 2 (External Secrets + AWS Secrets Manager)**

This is what Netflix, Uber, and Shopify use:
- Secrets stored in AWS (encrypted at rest, encrypted in transit)
- Kubernetes operator fetches and injects
- Automatic rotation support
- Audit trail in AWS CloudTrail

---

### A6.5 RBAC for Developers

**Current (Too Permissive):**

```hcl
enable_cluster_creator_admin_permissions = true
```

This gives the cluster creator (probably you) unlimited admin access.

**For production, implement role-based access:**

```bash
# 1. Create developer role (read-only)
kubectl create role developer \
  --verb=get,list,watch \
  --resource=deployments,pods,services,configmaps,secrets \
  -n retail-store

# 2. Create binding
kubectl create rolebinding developer-binding \
  --clusterrole=developer \
  --serviceaccount=retail-store:developers \
  -n retail-store

# 3. Create service account per developer
kubectl create serviceaccount alice -n retail-store
kubectl create serviceaccount bob -n retail-store

# 4. Grant role to service accounts
kubectl create rolebinding alice-developer \
  --clusterrole=developer \
  --serviceaccount=retail-store:alice \
  -n retail-store
```

**Or, for better developer UX (using user authentication):**

```bash
# 1. Configure OIDC provider (Okta, Azure AD, etc.)
# 2. Map users to groups
# 3. Use RBAC to grant groups permissions

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: developer
rules:
- apiGroups: [""]
  resources: ["pods", "pods/logs"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developer-group
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: developer
subjects:
- kind: Group
  name: "okta:engineering:platform-team"  # From OIDC provider
  apiGroup: rbac.authorization.k8s.io
EOF
```

**Deployment permissions:**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: retail-store
rules:
# Can deploy new versions
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "patch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments/rollback"]
  verbs: ["create"]
# Can update Helm values (via kubectl patch)
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "patch", "update"]
# Cannot delete deployments, change RBAC, etc.
# Prevents accidental damage
```

**Audit trail (required for compliance):**

```bash
# Enable audit logging
kubectl api-resources | grep auditpolicy

# Track who did what
kubectl get events -n retail-store | grep "user.*alice"

# Long-term: Send to CloudTrail
# Configure EKS audit logs to CloudWatch
```

---

## (Continued in Next Section Due to Length)

### A7 — A20: Remaining Answers

**Due to character limits, I'll create the second file with rounds 7-20 answers...**

---

**End of Round 6 Answers**

To avoid exceeding character limits, let me create the second part of the answers file now:
