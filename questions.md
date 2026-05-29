# DevOps Interview Questions - Retail Cloud-Native Platform

**Interviewer:** Principal DevOps Engineer at Sparrow Cloud  
**Candidate:** Full Repository Analysis - Production-Grade Technical Assessment

---

## Round 1 — Project Overview & Architecture Comprehension

### 1.1 Cluster Architecture Strategy
**Q1:** Looking at your EKS setup with system nodes (On-Demand, tainted) and spot worker nodes (Karpenter-managed), **why did you choose to completely segregate them instead of using a unified, simpler single node group with just On-Demand instances?** What's the cost-benefit tradeoff you're making here, and when would that tradeoff break down?

### 1.2 Spot Instance Economics
**Q2:** In your README, you claim "up to 80% compute cost reduction without sacrificing uptime." **Walk me through the math:**
- What's your estimated monthly compute spend on this cluster with spot?
- What would it be On-Demand?
- At what point would the operational complexity of spot management exceed the savings?
- How would you communicate this to finance if spot interruption rates spike?

### 1.3 Microservices State Design
**Q3:** All 5 services (UI, Cart, Catalog, Checkout, Orders) are marked as **stateless**. **But:**
- How do you ensure Cart operations don't lose data mid-transaction during a spot reclaim?
- Where IS the state actually stored (DynamoDB? Redis? RDS)?
- What if the state store becomes unavailable during a Karpenter consolidation wave?

### 1.4 Architecture Diagram Discrepancies
**Q4:** Your architecture diagram shows workloads across 3 AZs, but Terraform uses `slice(data.aws_availability_zones.available.names, 0, 3)` to select AZs. **What if your region only has 2 AZs available?** (This actually happens in some AWS regions.) Would your deployment fail, or gracefully degrade? Show me how Terraform handles this edge case.

### 1.5 Cluster Naming & Uniqueness
**Q5:** You use `random_string.suffix` to generate unique cluster names. **Explain:**
- Why is this necessary? What problem does it solve?
- What happens if `terraform destroy` fails and you re-run `terraform apply`?
- How would a new random suffix affect running workloads?
- Is this approach production-safe or a hack for rapid prototyping?

---

## Round 2 — Kubernetes & Node Management Deep Dive

### 2.1 Taint Propagation Strategy
**Q6:** The system node group has a `CriticalAddonsOnly=true:NoSchedule` taint. **In detail:**
- Which EKS addons automatically get the toleration for this taint?
- What happens if Prometheus (running on system nodes) doesn't have the toleration?
- How would you debug a situation where a critical addon is stuck in Pending?

### 2.2 Node Lifecycle & Spot Interruption
**Q7:** When a spot interruption warning fires (2-minute window):
1. Karpenter catches it via SQS
2. Cordons the node
3. Launches a replacement
4. Begins draining

**Where exactly can this process fail, and what are the consequences?**
- If Karpenter pod itself is on the doomed node?
- If all Karpenter replicas are on doomed nodes?
- If the replacement node fails to become Ready?
- If a pod has `terminationGracePeriodSeconds: 3600` (1 hour)?

### 2.3 Pod Disruption Budgets (PDBs)
**Q8:** Your `pdb.yaml` template supports both `minAvailable` and `maxUnavailable`. **But:**
- If a service has 3 replicas and `maxUnavailable: 2`, what happens during a mass spot reclaim affecting 5 nodes?
- How does `maxUnavailable: 1` interact with your HPA? Can HPA scale up while PDB is blocking evictions?
- In what scenarios would `minAvailable` be *wrong* for your services?

### 2.4 Topology Spread Constraints
**Q9:** Your deployment template references `topologySpreadConstraints`. **Explain:**
- What are the actual values you'd set? (maxSkew, topologyKey, whenUnsatisfiable policy?)
- How does topology spread interact with PDBs?
- If you have 3 replicas across 3 AZs but one AZ only has 1 available node, can scheduling still honor topology spread?
- How would you validate that topology spread is actually working in production?

### 2.5 Node Selection Complexity
**Q10:** Deployments use `nodeSelector: { role: spot-worker }` but also `nodeAffinity: { preferredDuringSchedulingIgnoredDuringExecution }` with spot lifecycle labels. **Why use both?** Isn't `nodeSelector` alone sufficient? What additional resilience does the affinity rule provide?

---

## Round 3 — Karpenter & Spot Management

### 3.1 Karpenter vs. Cluster Autoscaler
**Q11:** You migrated from ASG+NTH to Karpenter. **Deeply explain:**
- How does Karpenter make provisioning decisions faster than ASG?
- Cluster Autoscaler scales by changing ASG `desired_size`. Karpenter directly calls EC2 RunInstances. What's the latency difference in real-world scenarios?
- If you have 100 pending pods at once, how does Karpenter batch them vs. launching 100 individual RunInstances calls?

### 3.2 Instance Type Diversity Strategy
**Q12:** Your spot workers use 10 instance types across families (t3, t3a, m5, m5a):
- Why not just use the single cheapest option (e.g., `t3.medium`)?
- What's the interruption rate for single-type spot vs. your 10-type strategy? (Provide numbers or references.)
- If all 10 types hit capacity in a region, what's your fallback?
- How does Karpenter rank and pick from the 10? (Price? Availability? CPU/memory match?)

### 3.3 Bin-Packing Algorithm
**Q13:** Karpenter does active consolidation — it replaces underutilized nodes with smaller or fewer ones. **But:**
- How does it decide which nodes to consolidate? What's the underutilization threshold?
- What if consolidation triggers during a traffic spike?
- How do you prevent thrashing (constant consolidation/un-consolidation)?
- Show me how you'd monitor/alert on consolidation activity.

### 3.4 Karpenter IRSA Permissions
**Q14:** Looking at your `karpenter_controller` IAM policy:
- Why does `ec2:DescribeInstanceTypeOfferings` need `Resource: "*"`?
- What would happen if you removed `ec2:CreateTags` permission?
- The policy has `ec2:CreateFleet` — when and why would Karpenter use EC2 Fleet vs. RunInstances?
- Is this policy actually least-privilege, or could it be more restricted?

### 3.5 SQS Queue Configuration
**Q15:** The spot termination SQS queue has:
- `message_retention_seconds = 300` (5 min)
- `receive_wait_time_seconds = 20` (long poll)
- `visibility_timeout_seconds = 60`

**Question: If Karpenter takes >60s to process a spot interruption message, what happens?** Does it get reprocessed? Could duplicate spot evictions occur?

---

## Round 4 — Terraform Infrastructure as Code

### 4.1 Terraform State Management
**Q16:** Your Terraform creates VPC, EKS, node groups, Karpenter, ArgoCD, and monitoring. **Scenario: Your `terraform.tfstate` becomes corrupted mid-apply.** How would you:
1. Detect the corruption?
2. Recover?
3. Prevent data loss if Kubernetes resources already exist in AWS but aren't in state?
4. Should you use `terraform import` to fix it?

### 4.2 Module Versioning
**Q17:** You pin:
- `terraform-aws-modules/eks/aws` to `~> 20.24`
- `terraform-aws-modules/vpc/aws` to `~> 5.8`

**Explain:**
- What does `~> 20.24` mean exactly? (e.g., allows up to 20.99.99?)
- What breaking changes could happen within this range?
- How would you test a minor version upgrade before applying to production?
- The UPGRADE-21.0.md file is provided — if you upgraded to v21, which resources would require changes and how would you automate the migration?

### 4.3 VPC Locals Computation
**Q18:** Your `locals.tf` computes subnets with:
```hcl
private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 10)]
public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k)]
```
With `vpc_cidr = "10.0.0.0/16"`:
- What are the actual CIDR ranges for public subnets?
- What for private subnets?
- Why start private at offset `k + 10` instead of just `k + 3`?
- If you add more AZs (say, 4 instead of 3), does this logic still work correctly?

### 4.4 Managed vs. Self-Managed Resources
**Q19:** The module uses `manage_default_network_acl`, `manage_default_route_table`, and `manage_default_security_group`. **Why manage these instead of creating custom ones?**
- What risks does "managing defaults" introduce?
- If you accidentally destroy the VPC but resources exist, are defaults automatically cleaned up?
- In a shared AWS account (multiple projects), does managing defaults cause conflicts?

### 4.5 Terraform Validation & Testing
**Q20:** You provide `validation` blocks for `environment` variable (only dev/staging/prod allowed). **But:**
- What validations are MISSING?
- How would you validate that `spot_min_size <= spot_desired_size <= spot_max_size`?
- How would you prevent someone from setting `enable_single_nat_gateway = true` in prod?
- Should these be in Terraform or a separate validation tool (like Checkov)?

---

## Round 5 — CI/CD & GitOps

### 5.1 ArgoCD Sync Policy
**Q21:** Your retail-store-cart ArgoCD Application has:
```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
```
**Deeply:**
- What's the risk of `prune: true`? (What if someone manually creates a resource?)
- What if the namespace doesn't exist but CreateNamespace=true and the app times out?
- `selfHeal: true` means ArgoCD resyncs if you manually change resources. When would this be DANGEROUS?
- How do you prevent accidental namespace deletion via ArgoCD?

### 5.2 ArgoCD Application Sync Waves
**Q22:** You use `sync-wave: "1"` annotation on retail-store-cart. **But:**
- Why not sync-wave 0? Or negative waves?
- What's the correct wave ordering for: namespace → secrets → deployments → ingress?
- If cart has sync-wave 1 and catalog has sync-wave 2, but cart depends on catalog database tables, would that cause issues?
- How do you handle circular dependencies between services?

### 5.3 Helm Values Overlay Strategy
**Q23:** Each service has both `chart/values.yaml` and `charts/values.yaml` (two different directories). **What's the difference?** Are these:
- Environment-specific overrides (dev vs. prod)?
- Stateful vs. stateless versions?
- Old and new versions during migration?
- Something else?

### 5.4 GitOps Deployment Flow
**Q24:** Walk me through what happens when a developer:
1. Commits a new version tag to a service Dockerfile
2. CI/CD builds and pushes the image to ECR
3. Updates the Helm values.yaml with the new image tag
4. Creates a PR and merges to main

**How does ArgoCD detect this change?** (Git webhook? Polling? What's the detection lag?)

### 5.5 Handling Helm Template Errors
**Q25:** What happens if a Helm template has a syntax error (e.g., `{{ .Values.foo.bar.baz }}` but `.baz` doesn't exist)?
- Does ArgoCD sync fail? Succeed with partial manifests?
- How would you catch this before applying?
- Should you test templates in CI/CD?

---

## Round 6 — Security & RBAC

### 6.1 Pod Security & Dockerfile Hardening
**Q26:** Your Java/Spring Boot Dockerfiles use:
```dockerfile
RUN useradd --user-group --uid 1000 appuser
USER appuser
```
**But in values.yaml you also set:**
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
```
**Questions:**
- If both Dockerfile and Helm set the user, which takes precedence?
- Why set a read-only root filesystem? What breaks, and how do you handle temp files?
- How do Java heap dumps work with read-only root? (Is `/tmp` needed?)
- Should you use a seccomp profile too?

### 6.2 IRSA Security
**Q27:** Karpenter uses IRSA to assume an AWS role. **But:**
- What's the attack surface if a compromised pod could reach the Karpenter service account token?
- How would you detect if someone was impersonating Karpenter?
- Should you restrict Karpenter's IAM role to specific node names, AZs, or VPCs?
- Could a malicious pod create its own service account and assume arbitrary roles?

### 6.3 Network Policies
**Q28:** I don't see NetworkPolicy manifests in your project. **Why not?**
- Do you assume Traefik provides network isolation?
- Should microservices have deny-all default policies with explicit allow rules?
- How would you implement network policies for: UI → Catalog, Cart → DynamoDB?

### 6.4 Secret Management
**Q29:** I don't see a secrets management strategy (HashiCorp Vault, AWS Secrets Manager, Sealed Secrets). **How do you handle:**
- Database passwords
- API keys
- TLS certificates (beyond cert-manager)
- Artifact registry credentials (the `regcred` in your values)?

### 6.5 RBAC for Developers
**Q30:** Currently, you enable `enable_cluster_creator_admin_permissions = true`. **In production:**
- How would you restrict developer access?
- Should different teams have different namespaces with RBAC?
- Can developers deploy anything, or only certain Helm charts?
- How do you audit who deployed what and when?

---

## Round 7 — Observability & Monitoring

### 7.1 Prometheus Stack Configuration
**Q31:** You enable `kube_prometheus_stack` via eks-blueprints-addons. **But:**
- What's the actual helm chart version being deployed?
- Does it include Alertmanager? How would you route alerts?
- Where are Prometheus metrics stored? (In-memory? EBS volume?)
- If Prometheus dies, are metrics lost forever, or can you restore from a backup?

### 7.2 Metrics Strategy
**Q32:** In your deployment template, you reference metrics with `metrics.enabled` annotation. **But:**
- Are you actually scraping Spring Boot `/actuator/metrics` endpoints?
- Is Prometheus auto-discovering pods with annotations, or do you need ServiceMonitor CRDs?
- What's the query latency if you're asking "what's the p99 latency for the cart service over 24 hours"?
- How do you prevent cardinality explosion? (e.g., if cart has 1000 unique SKUs as labels)

### 7.3 Alerting for Spot Events
**Q33:** You have `spot-alerts.yaml` in `k8s/monitoring/`. **What alerts does it define?**
- Alert when 3+ nodes are cordoned within 5 minutes?
- Alert when Karpenter consolidation is running?
- Alert when spot interruption rate exceeds 5%?
- How do you distinguish between expected spot reclaims and unexpected node failures?

### 7.4 Observability Gaps
**Q34:** Looking at your monitoring setup, what's MISSING?
- Distributed tracing (Tempo, Jaeger)?
- Log aggregation (Loki, ELK)?
- Custom business metrics?
- Service mesh metrics (if using Istio)?
- Which of these would you add first and why?

### 7.5 Debugging Production Issues
**Q35:** A user reports "the cart is slow." Walk me through your investigation:
1. Where do you look first? (Prometheus? Pod logs? Node CPU?)
2. How do you determine if it's the cart service, the database, or network latency?
3. What queries would you run?
4. If you can't find the root cause in metrics, what's your next step?

---

## Round 8 — Networking & Ingress

### 8.1 Traefik vs. NGINX
**Q36:** You chose Traefik (Gateway API) over NGINX Ingress. **Deep comparison:**
- Traefik dynamically discovers HTTPRoute resources; NGINX uses Ingress annotations.
- Performance: At 10,000 req/s, which architecture would strain first?
- Complexity: Is Gateway API actually simpler, or just different?
- If you needed mutual TLS (mTLS) between services, would Traefik suffice or would you need a service mesh?

### 8.2 Load Balancer Configuration
**Q37:** Traefik creates an AWS NLB (Network Load Balancer). **But:**
- How does the NLB know which port to listen on? (Does Traefik tell it?)
- What's `externalTrafficPolicy: Local`? Why is this important?
- If you have 3 Traefik replicas on 3 nodes, does the NLB distribute to all 3, or sticky?
- How do you handle certificate rotation for HTTPS?

### 8.3 Ingress to Application Routing
**Q38:** When a user makes a request:
```
internet:443 → AWS NLB → Traefik Pod → Retail-Store Service → Cart Pod
```
**Explain each hop:**
- How does the NLB know which Traefik pod to route to?
- How does Traefik know which service to route to? (Using HTTPRoute resource?)
- Is this service DNS resolution or direct IP?
- If cart crashes mid-request, what happens?

### 8.4 DNS & Custom Domains
**Q39:** You mention "Custom Domain Setup (Optional)" in README but don't explain. **How would you:**
- Register a custom domain (e.g., retail-store.example.com)?
- Update DNS records to point to the AWS NLB endpoint?
- Generate TLS certs for the custom domain?
- Handle cert renewal?

### 8.5 Networking Debugging
**Q40:** A user can reach the UI but cart API requests fail with timeout. **Debug plan:**
1. Check Traefik logs — seeing the request?
2. Check cart pod logs — receiving the request?
3. Check network policy — is there a deny?
4. Check service endpoints — how many cart pods are registered?
5. Show me the actual kubectl commands and what output you'd expect.

---

## Round 9 — Troubleshooting & Incident Response

### 9.1 Pod Stuck in Pending
**Q41:** A cart pod is stuck in Pending for 10 minutes. **Walk me through your debugging:**
```bash
kubectl describe pod <name>
kubectl get nodes
kubectl top nodes
```
**What would each command tell you? What are the possible root causes?**

### 9.2 Node Termination Cascade
**Q42:** During an AWS maintenance window, Karpenter receives a rebalance recommendation for node-A. **But:**
- Node-A has 5 pods running
- One pod has `terminationGracePeriodSeconds: 300`
- The other 4 pods fail to gracefully terminate
- The 2-minute warning expires
- AWS terminates node-A anyway

**What happens to the 4 pods that didn't terminate gracefully?**

### 9.3 Karpenter Not Provisioning
**Q43:** You submit 10 pods, but Karpenter hasn't provisioned new nodes after 3 minutes. **Diagnostic steps:**
1. Check Karpenter controller logs — any errors?
2. Check Karpenter NodePools — are they valid?
3. Check EC2 account limits — how many instances can you launch?
4. Check AWS credentials — are they valid?

**Show me the actual kubectl and AWS CLI commands.**

### 9.4 ArgoCD Stuck in Syncing
**Q44:** An ArgoCD Application shows "Syncing" but never completes. **Root causes and fixes:**
- Karpenter is waiting for node capacity?
- A pod's liveness probe is failing?
- ArgoCD is stuck waiting for a hook (e.g., pre-sync job)?
- Git connectivity is broken?

**For each, what's your investigation and remediation?**

### 9.5 Memory Leak in Cart Service
**Q45:** Cart service is gradually consuming more memory. After 48 hours it hits the 512Mi limit and crashes. **How would you:**
1. Detect this programmatically (monitoring)?
2. Identify the memory leak (profiling)?
3. Temporarily mitigate it (scaling)?
4. Permanently fix it (code)?
5. Prevent it in the future (testing)?

---

## Round 10 — Production Readiness & Disaster Recovery

### 10.1 Multi-Environment Deployment
**Q46:** Currently, you have a single Terraform module for one environment. **To support dev/staging/prod:**
- Should you use separate Terraform workspaces?
- Separate AWS accounts?
- Separate Git branches?
- What's the risk of a single misconfiguration affecting all three?

### 10.2 Backup & Recovery Strategy
**Q47:** Your EKS cluster is running. **If AWS deletes your cluster by mistake:**
1. How long until you can redeploy?
2. Do you lose data? (What data is persisted outside the cluster?)
3. How would you test disaster recovery? (Regularly?)

### 10.3 Cost Optimization Opportunities
**Q48:** You use open-source monitoring instead of CloudWatch. **But:**
- Do you actually save money? (Calculate: EBS for Prometheus storage cost vs. CloudWatch API costs)
- What about data retention? (30-day default Prometheus scrape? CloudWatch logs retention?)
- Is this a good tradeoff or just avoiding vendor lock-in?

### 10.4 Scaling Limits
**Q49:** Currently:
- System nodes: 2-4
- Spot workers: 2-20
- Cart replicas: 3-10

**But what if:**
- Black Friday traffic hits and you need 1,000 cart replicas?
- AWS has spot capacity issues and you need 100+ On-Demand nodes?
- A single microservice wants 50GB RAM but your largest instance is 256GB?

**How do you scale beyond these limits?**

### 10.5 Compliance & Audit
**Q50:** You're deploying this for a healthcare company (HIPAA) or financial company (PCI). **What's missing?**
- Encryption at rest?
- Encryption in transit?
- Audit logging?
- RBAC/authentication?
- Data residency requirements?

---

## Round 11 — Advanced DevOps & SRE Practices

### 11.1 Cost Optimization Deep Dive
**Q51:** Spot interruption costs you time to replace pods, and consolidation can cause unexpected restarts. **Calculate:**
- Mean Time To Recovery (MTTR) for a spot reclaim?
- How many failed carts (lost revenue) per reclaim?
- Break-even point where 80% spot savings < cost of interruptions?
- At what point would you switch to pure On-Demand?

### 11.2 Karpenter Consolidation Edge Cases
**Q52:** Karpenter consolidation actively replaces nodes. **But:**
- What if consolidation removes a node while a pod is in the middle of a database transaction?
- What if consolidation fragments your cluster (2 nodes with 4 cores unused each vs. 1 node fully used)?
- Can consolidation cause cascading failures? (Node removal → pods reschedule → new node needed → consolidation triggered again?)

### 11.3 GitOps Drift Detection
**Q53:** You use ArgoCD with `selfHeal: true`, but someone manually patches a pod. **Then:**
- How long until ArgoCD detects the drift?
- Does ArgoCD undo the manual patch or merge changes?
- What if the manual change was a critical hotfix that needs to stay?
- Should you disable manual kubectl changes entirely in production?

### 11.4 Helm Chart Versioning Strategy
**Q54:** Each service has its own Helm chart. **But:**
- Are chart versions tied to application versions? (v1.0.0 app → v1.0.0 chart?)
- Can you deploy v1.2.0 app with v1.0.0 chart?
- How do you test chart changes? (Unit tests? Integration tests?)
- Should charts be versioned separately or together?

### 11.5 Canary Deployments
**Q55:** You're deploying a risky change to the cart service. **How would you:**
1. Deploy to 10% of replicas first?
2. Monitor metrics (error rate, latency)?
3. Automatically rollback if errors spike?
4. Gradually roll forward?

**Does ArgoCD support this natively, or do you need Flagger/Argo Rollouts?**

---

## Round 12 — Behavioral & Ownership Questions

### 12.1 Architectural Decision Documentation
**Q56:** Why did you choose Karpenter over Cluster Autoscaler? **Explain:**
- What trade-offs did you evaluate?
- What were the alternatives?
- When would you regret this choice?
- If Karpenter became unmaintained, what's your exit strategy?

### 12.2 Production Incident Post-Mortem
**Q57:** Imagine a spot reclaim causes a cascade of failures:
1. Node is reclaimed mid-transaction
2. Karpenter replacement node fails to provision
3. Cart pods crash and can't reschedule
4. Revenue impact: $50K/hour

**Walk me through your incident response:**
- How do you communicate with stakeholders?
- How do you restore service?
- What's your post-mortem process?
- What would you change?

### 12.3 Technical Debt vs. Feature Velocity
**Q58:** You've been asked to add support for stateful workloads (e.g., databases) to your Karpenter cluster. **But:**
- This requires switching to On-Demand nodes (more expensive)
- This requires persistent storage (EBS/EFS complexity)
- This requires backup/recovery planning
- This would delay shipping new features by 4 weeks

**How do you prioritize this?**

### 12.4 Team Scaling & Documentation
**Q59:** You're the only DevOps engineer on a growing team. **Your Karpenter setup is complex (spot interruption handling, IRSA, EventBridge).**
- How do you document this for the team?
- What's the minimum knowledge an SRE needs to on-call this system?
- When would you hire another DevOps engineer?
- How do you prevent knowledge silos?

### 12.5 Disagreement with Stakeholders
**Q60:** Your security team says "no spot instances, too risky." But business wants 80% cost savings. **How do you:**
- Present the data?
- Find middle ground?
- Build consensus?
- Escalate if needed?

---

## Round 13 — Deep Kubernetes Internals

### 13.1 Pod Scheduling Algorithm
**Q61:** When a pod is created, Kubernetes scheduler places it on a node. **In your setup:**
- Cart pod requests 256m CPU and 512Mi memory
- You have nodes with 4, 8, 16, 32 core options (spot)
- Some nodes are cordoned (spot reclaiming)
- Some nodes have PDBs blocking evictions

**Walk me through the scheduling algorithm:**
1. Filter feasible nodes (which nodes CAN run this pod?)
2. Score feasible nodes (which is BEST?)
3. Apply affinity/anti-affinity rules (prefer spot nodes)
4. Place the pod

**What's the exact scoring function Kubernetes uses?**

### 13.2 Resource Requests vs. Limits
**Q62:** Cart pods have:
```yaml
resources:
  requests:
    cpu: 256m
    memory: 512Mi
  limits:
    memory: 512Mi
```
**But no CPU limit.** **Why?**
- What happens if CPU exceeds 256m?
- What happens if memory exceeds 512Mi?
- Why set memory.limit but not cpu.limit?
- What's the performance impact of limit enforcement?

### 13.3 QoS Classes & Eviction Policies
**Q63:** Kubernetes assigns QoS classes (Guaranteed, Burstable, BestEffort). **Your pods are Burstable** (requests < limits). **When node memory is low:**
- Which pods get evicted first? (Guaranteed, Burstable, or BestEffort?)
- Can you influence eviction order? (priority classes?)
- What's the difference between OOMKilled and evicted?

### 13.4 Init Containers & Startup Probes
**Q64:** Your deployment doesn't show init containers, but should it? **Consider:**
- Cart needs to wait for DynamoDB to be accessible
- Or cart needs to migrate database schema on first startup

**How would you implement this?** (Init container? StartupProbe? What's the difference?)

### 13.5 Sidecar Injection & Namespace Labels
**Q65:** If you added a service mesh (Istio), you'd inject sidecar proxies into pods. **How would this work?**
- You label a namespace: `istio-injection=enabled`
- MutatingWebhookConfiguration auto-injects sidecars
- Sidecars intercept traffic

**But:**
- When are sidecars injected? (Pod creation? During run?)
- How do you prevent sidecar injection in certain pods?
- What's the performance/resource overhead?

---

## Round 14 — Docker & Container Optimization

### 14.1 Multi-Stage Build Efficiency
**Q66:** All your Dockerfiles use multi-stage builds. **Example: Cart service:**
```dockerfile
FROM maven:3.9.9-eclipse-temurin-21 AS build-env
# ... compile ...
FROM eclipse-temurin:21-jre-jammy
# ... runtime ...
```
**Optimize this:**
- How much smaller is the final image vs. single-stage?
- Could you optimize the build-env stage further? (Caching? Layer ordering?)
- Should you use a different base image (Alpine, distroless, UBI)?
- What's the size difference between `eclipse-temurin:21-jre-jammy` vs. `eclipse-temurin:21-jre-alpine`?

### 14.2 Security: Non-Root User
**Q67:** All your services run as non-root (UID 1000). **But:**
- What if the app needs to bind to a port <1024?
- What if it needs to mount /etc/config as read-only?
- Can the non-root user write to /tmp for temp files?
- Is this actually effective as a security control, or just best practice?

### 14.3 Read-Only Root Filesystem
**Q68:** You set `readOnlyRootFilesystem: true`. **But:**
- Java needs `/tmp` for heap dumps
- Most apps write to /var/log locally
- How do you mount writable volumes without breaking the contract?
- What's the actual security gain?

### 14.4 Image Scanning & Registry
**Q69:** I don't see image scanning (Trivy, Anchore) in your pipeline. **Questions:**
- Do you scan images before pushing to ECR?
- Do you scan images regularly in ECR?
- What's your policy on vulnerabilities? (Fix immediately? Accept risk?)
- How do you prevent developers from pushing images with critical CVEs?

### 14.5 Base Image Selection
**Q70:** Catalog uses `distroless/static-debian12:nonroot`. **Why?**
```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
```
**But Cart uses `eclipse-temurin:21-jre-jammy`.** **Why the difference?**
- File size comparison?
- Attack surface (available utilities)?
- Debuggability?
- When would you use distroless vs. standard images?

---

## Round 15 — AWS & Infrastructure Specifics

### 15.1 IMDSv2 Enforcement
**Q71:** All nodes have:
```hcl
metadata_options = {
  http_endpoint               = "enabled"
  http_tokens                 = "required"  # IMDSv2
  http_put_response_hop_limit = 2
}
```
**Explain:**
- What's IMDSv1 vs. IMDSv2?
- Why is v2 more secure? (SSRF vulnerability fix?)
- What's `http_put_response_hop_limit = 2`? (Why 2 and not 1?)
- If someone runs a container with `http_put_response_hop_limit = 1`, does it override the node setting?

### 15.2 Security Groups
**Q72:** You have security group rules allowing:
- HTTP/HTTPS from 0.0.0.0/0 to load balancer
- NodePort range (30000-32767) within VPC

**But:**
- Should you restrict HTTPS to specific IPs?
- What's the NodePort range for? (When would you use NodePort instead of LoadBalancer?)
- Are there egress rules? (Pods need to reach out to external APIs)
- How do you prevent a malicious pod from port scanning other pods?

### 15.3 NAT Gateway Costs
**Q73:** You enable `enable_nat_gateway = true` and `single_nat_gateway = true`. **But:**
- What's the monthly cost of a NAT gateway? (~$32)
- What's the data transfer cost? (~$0.045 per GB)
- If your services download 1TB of data daily, what's the monthly cost?
- Would Kubernetes Network Policy be cheaper than NAT?

### 15.4 EKS Cluster Upgrades
**Q74:** You're running Kubernetes 1.35. **To upgrade to 1.36:**
1. EKS control plane first (managed by AWS)
2. Then managed node groups (replace nodes gradually)
3. Then Karpenter nodes (need to consolidate/replace?)

**Walk me through the upgrade process:**
- How long does it take?
- Do you lose traffic?
- How do you validate compatibility with addons/charts?
- What if a pod fails to migrate during the upgrade?

### 15.5 AWS Outage Resilience
**Q75:** AWS us-west-2 has a regional outage. **Your cluster spans 3 AZs within us-west-2.** **All go down.** **Now:**
- How long until users can access the retail store?
- Do you have disaster recovery in another region?
- How would you implement multi-region failover?
- Is active-active or active-passive cheaper?

---

## Round 16 — Complex Scenarios & Troubleshooting

### 16.1 Cascading Failure Scenario
**Q76:** A cascade of failures occurs:
1. Catalog service gets DDoS'd
2. Response time goes from 100ms to 30s
3. Cart service calls catalog and times out
4. Cart pods start using 100% CPU in retry loops
5. Cart's HPA scales up to max replicas (10)
6. Karpenter provisions new spot nodes to handle new pods
7. While provisioning, more spot nodes are reclaimed
8. Workloads can't reschedule

**How do you prevent/detect/recover from this cascade?**

### 16.2 Terraform Drift
**Q76 (alternate):** Someone manually creates an S3 bucket for backups in AWS console. **Then:**
- `terraform plan` doesn't show it (it wasn't in Terraform)
- But it exists in AWS
- Later, you run `terraform destroy`
- Does the S3 bucket get deleted? (No, because it wasn't in state)
- Is this good or bad?

**How do you prevent Terraform drift?**

### 16.3 ArgoCD Secrets Rotation
**Q77:** Your ArgoCD repo contains image pull secrets (`regcred`) as Kubernetes Secrets. **But they're in Git.** **If ECR credentials rotate:**
1. How do you update the secret?
2. Do you commit the new secret to Git? (Security risk!)
3. Or use sealed-secrets/vault?

**What's your strategy?**

### 16.4 Helm Template Debugging
**Q78:** You're debugging a Helm template that's producing invalid YAML. **Steps:**
```bash
helm template retail-store-cart src/cart/chart/
helm template ... | kubectl apply -f - --dry-run=client
```

**But it still fails. What's your next step?** (Use `--debug`? Check `values.yaml` syntax? Validate the template logic?)

### 16.5 Pod Networking Failure
**Q79:** UI pod can't reach Catalog pod. Both are running. **Debugging:**
```bash
kubectl exec ui-pod -- curl http://catalog-service:8080/health
# Connection timeout
```

**What could be wrong?**
- DNS resolution failure (CoreDNS down)?
- Network policy blocking?
- Service has no endpoints?
- Catalog pod not listening on 8080?
- Firewall/security group rule?

**Show me the debugging commands.**

---

## Round 17 — Open-Ended Architecture Questions

### 17.1 Design Critique
**Q80:** If you were reviewing this architecture from a Senior Platform Engineer at Netflix, what would you change?
- Cost optimization?
- Reliability?
- Observability?
- Developer experience?

### 17.2 Evolution Path
**Q81:** You're in year 1 of this project. **What's the evolution path for year 2-3?**
- Multi-region?
- Multi-cluster mesh?
- Stateful workloads?
- Real-time analytics?
- Compliance requirements?

### 17.3 Greenfield Redesign
**Q82:** If you could redesign this from scratch TODAY (with 2024 tools), what would you change?
- Service mesh (Istio/Linkerd)?
- Different container runtime (containerd, CRI-O)?
- Operators vs. Helm?
- Platform-as-a-Service abstraction?

### 17.4 Trade-off Analysis
**Q83:** You chose:
- Karpenter over Cluster Autoscaler
- Traefik over NGINX
- Open-source monitoring over CloudWatch

**For each, articulate the tradeoff:**
- When would the alternative be better?
- What's your decision framework?
- Would you choose differently at scale (10x or 100x)?

### 17.5 Learning & Growth
**Q84:** What do you NOT know about this architecture?
- What would you learn next?
- Where are your knowledge gaps?
- How do you stay current with cloud-native tools?

---

## Round 18 — Performance & Optimization

### 18.1 Pod Startup Time
**Q85:** Cart pods take ~30s to start (Spring Boot initialization). **But:**
- HPA scales based on CPU. When traffic spikes, HPA scales up.
- But new pods take 30s to be ready.
- In those 30s, traffic is still going to existing pods.
- How do you prevent overload during this lag?

### 18.2 Database Connection Pooling
**Q86:** Cart service connects to DynamoDB. **But:**
- Each pod has its own connection pool
- With 10 cart pods, that's 10 independent pools
- DynamoDB has rate limits
- How do you ensure pods aren't hammering DynamoDB?

### 18.3 Caching Strategy
**Q87:** Catalog service (product listing) is expensive to compute. **How would you cache?**
- Cache in-pod (Redis/Memcached)?
- Cache in a shared store (ElastiCache)?
- HTTP caching headers in Traefik?
- All of above?

### 18.4 Request Latency Breakdown
**Q88:** A user reports "the site is slow." **P99 latency is 5s, P50 is 200ms.** **Where's the latency?**
- Network latency to AWS?
- TLS handshake?
- Load balancer → Traefik hop?
- Traefik → service mesh discovery?
- Service mesh → application pod?
- Application processing?

**How do you measure each?**

### 18.5 Spot Interruption Performance
**Q89:** When a spot node is interrupted, the replacement node takes time to:
1. Provision (30-60s)
2. Join cluster (10-20s)
3. Pull image (20-40s)
4. Start pod (10-30s)

**Total: 70-150s of reduced capacity.** **How do you prevent traffic loss?**
- Pre-warm nodes?
- Overprovisioning?
- Pod affinity to keep replicas apart?

---

## Round 19 — Kubernetes Advanced Features

### 19.1 Custom Resource Definitions (CRDs)
**Q90:** Karpenter uses CRDs for NodePool and EC2NodeClass. **But:**
- Have you considered other CRDs? (
- Argo Rollouts for canary deployments?
- Crossplane for AWS resource management via k8s?
- Why mix declarative Kubernetes CRDs with imperative Terraform?

### 19.2 Operator Pattern
**Q91:** Karpenter is a controller/operator. **Operators are powerful but complex.**
- What's an operator? (Custom controller + CRDs?)
- When would you build one?
- Risks of operators (e.g., a bug can break the whole cluster)?

### 19.3 Admission Controllers
**Q92:** Kubernetes has MutatingAdmissionWebhooks and ValidatingAdmissionWebhooks. **Use cases:**
- Mutating: Inject sidecar proxies, add labels
- Validating: Enforce policies (e.g., "no public container registries")

**Should you implement webhook to enforce:**
- Resource requests/limits mandatory?
- No root containers?
- Specific image registries only?
- Service Account tokens immutable?

### 19.4 Static Pod Admission Control
**Q93:** Pod Security Standards (PSS) are built-in Kubernetes admission controllers. **Three levels:**
- Restricted (hardest)
- Baseline
- Unrestricted

**Which should you apply cluster-wide? Per-namespace?** **How would you enforce PSS without breaking existing workloads?**

### 19.5 Workload Identity & Automation
**Q94:** You use IRSA for Karpenter. **But:**
- Every microservice also needs AWS permissions (read from S3, write to DynamoDB)
- Should every service have its own IAM role?
- Or should they all share one role?
- What's the security tradeoff?

---

## Round 20 — Real-World Operational Challenges

### 20.1 Quota & Limits Issues
**Q95:** Scenario: You try to create 50 new spot nodes via Karpenter. **But AWS says "you've hit your spot instance limit."** **Now:**
1. How do you increase the limit? (Support ticket? Automated?)
2. How long does it take?
3. What's your short-term mitigation? (Fallback to On-Demand?)
4. How do you prevent this from happening again?

### 20.2 Networking Complexity
**Q96:** You have:
- 3 AZs
- 3 Public subnets
- 3 Private subnets (where pods run)
- 1 NAT Gateway (bottleneck?)
- Traefik Load Balancer

**If the NAT Gateway becomes saturated:**
- What breaks? (Pods can't reach external APIs?)
- How do you scale the NAT?
- Cost implications?
- Alternative: Use NAT instances?

### 20.3 State & Persistence
**Q97:** You claim all services are stateless. **But:**
- Orders need to be persisted (database)
- User sessions need to be stored
- File uploads need storage

**Where does this state actually live?** Is it:
- Outside the cluster (managed AWS services)?
- Inside the cluster (PersistentVolume)?
- Distributed (eventually consistent)?

**What's your backup strategy?**

### 20.4 Secrets & Credential Rotation
**Q98:** Database password expires every 90 days. **How do you:**
1. Rotate it without downtime?
2. Ensure all pods get the new password?
3. Prevent cached old passwords from being used?
4. Audit who rotated it and when?

### 20.5 On-Call Incidents
**Q99:** You're on-call. Slack alert fires at 3 AM: "Cart service error rate 50%."
1. What's your investigation process?
2. How do you decide: quick rollback vs. deep debugging?
3. How do you communicate with stakeholders?
4. What's the post-mortem?

### 20.6 Hiring & Knowledge Transfer
**Q100:** Your company is growing. You need to hire 3 more SREs.
1. How do you onboard them to this Karpenter + ArgoCD + Traefik stack?
2. What's the minimum knowledge they need?
3. When do they go on-call?
4. How do you prevent knowledge silos?

---

## Round 21 — Final Architecture Synthesis

### 21.1 Complete System Walkthrough
**Q101:** A user makes a request to buy something:
```
1. User clicks "Buy" on retail-store.example.com
2. Browser makes HTTPS POST to /checkout
3. ... (what happens next)
```

**Walk me through the complete request flow:**
- DNS resolution
- TLS handshake
- Route through AWS NLB → Traefik → checkout service
- Checkout calls cart service (how?)
- Cart calls DynamoDB (how?)
- Response comes back
- Transaction is persisted
- User sees confirmation

**Show me every hop and where failures could occur.**

### 21.2 Deployment of a New Feature
**Q102:** A developer wants to add a new field to the cart API (e.g., "color preference" for each item). **Walk me through:**
1. Code change (in src/cart/)
2. Docker build (Dockerfile change?)
3. Git commit (to which branch?)
4. CI/CD triggers (what tests run?)
5. Image pushed to ECR (with what tag?)
6. Helm chart updated (values.yaml? Chart.yaml?)
7. Merge to main
8. ArgoCD detects change (how long?)
9. New pods spin up (old pods gracefully terminated?)
10. Canary validation (how?)
11. Full rollout

**Every step in detail.**

### 21.3 Disaster Recovery Simulation
**Q103:** You practice disaster recovery (should do monthly). **Scenario: Entire EKS cluster is deleted.** **You run:**
```bash
terraform apply
```

**Walk me through what happens:**
1. VPC created
2. Subnets created
3. EKS control plane created (how long?)
4. Node groups provisioned (system first or spot first?)
5. Addons installed (Karpenter, ArgoCD, monitoring)
6. ArgoCD syncs applications (from which Git branch?)
7. Applications become healthy (liveness probes?)

**How long does full recovery take? Hours? Minutes?**

### 21.4 Cost Optimization Retrospective
**Q104:** After 1 year running this cluster:
1. What was actual vs. budgeted cost?
2. Biggest cost drivers? (EC2? Networking? Storage?)
3. What worked? What didn't?
4. If you had to cut costs by 50%, where would you focus?
5. What would you do differently?

### 21.5 Your Personal DevOps Philosophy
**Q105:** Synthesize everything. **Your philosophy is:**
- Automation over manual toil?
- Reliability over cost?
- Simplicity over feature richness?
- How do these play out in THIS architecture?

---

## SCORING NOTES FOR INTERVIEWER

**Pass Criteria:**
- Demonstrates deep understanding of Karpenter, spot interruption handling, and node lifecycle
- Can explain architecture decisions and tradeoffs
- Understands Kubernetes internals (scheduling, QoS, admission control)
- Can debug production scenarios methodically
- Recognizes limitations and missing components
- Shows growth mindset (knows what they don't know)

**Red Flags:**
- Treats this as a generic EKS setup (doesn't understand why specific choices were made)
- Can't explain spot interruption handling flow
- Defensive about architectural decisions
- No awareness of operational burden (only highlights benefits)
- Treats infrastructure code as "write-once, forget-it"

**Strong Signals:**
- Asks clarifying questions
- Identifies architecture gaps (secrets management, multi-region, etc.)
- Proposes concrete improvements
- Explains tradeoffs (cost vs. complexity, etc.)
- Thinks about operational burden on-call

---

**End of Questions Document**

*Total: 105+ high-complexity DevOps interview questions spanning Kubernetes, AWS, Terraform, GitOps, Docker, SRE practices, troubleshooting, and production operations.*
