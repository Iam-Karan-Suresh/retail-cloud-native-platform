# Karpenter Migration Runbook — ASG + NTH → Karpenter Spot Provisioning

> **Audience:** On-call / platform engineer  
> **Estimated Duration:** 2–4 hours (plus 24h observation period)  
> **Risk Level:** Medium — workload disruption is bounded by PDBs and disruption budgets  
> **Rollback:** Scale ASG back up, remove Karpenter taint — pods return to ASG nodes

---

## Prerequisites

- [ ] `kubectl` configured for the target cluster
- [ ] `terraform` CLI available with state access
- [ ] AWS CLI configured with sufficient permissions
- [ ] Confirm cluster is healthy: `kubectl get nodes` — all nodes `Ready`
- [ ] Confirm existing PDBs are in place for critical workloads:
  ```bash
  kubectl get pdb --all-namespaces
  ```
- [ ] Verify the SQS queue is receiving events:
  ```bash
  aws sqs get-queue-attributes \
    --queue-url $(terraform output -raw spot_termination_sqs_queue_url) \
    --attribute-names ApproximateNumberOfMessages
  ```

---

## Step 1 — Deploy Karpenter Infrastructure (Terraform)

**What:** Create IRSA role, IAM policy, EKS access entry, and Helm release.

```bash
# Review the plan — must show only additive changes
terraform plan -target=module.karpenter_irsa \
               -target=aws_iam_policy.karpenter_controller \
               -target=aws_eks_access_entry.karpenter_node \
               -target=helm_release.karpenter

# Apply (no existing resources should be destroyed)
terraform apply -target=module.karpenter_irsa \
                -target=aws_iam_policy.karpenter_controller \
                -target=aws_eks_access_entry.karpenter_node \
                -target=helm_release.karpenter
```

### Validation

- [ ] Karpenter pods are running:
  ```bash
  kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
  ```
  Expected: 2 pods in `Running` state (leader + standby)

- [ ] Karpenter logs show no errors:
  ```bash
  kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50
  ```

- [ ] IRSA is working (check for STS assume-role in logs, no `AccessDenied`)

---

## Step 2 — Deploy EC2NodeClass and NodePool (with migration taint)

**What:** Apply the Kubernetes manifests. The NodePool has a `karpenter.sh/migration=true:NoSchedule` taint — no workloads will land on Karpenter nodes yet.

> **⚠️ IMPORTANT:** Before applying, replace the placeholder variables in `karpenter-nodeclass.yaml`:
> - `${CLUSTER_NAME}` → actual cluster name (from `terraform output -raw cluster_name`)
> - `${NODE_ROLE_NAME}` → node IAM role name (from `terraform output` or AWS console)
> - `${ENVIRONMENT}` → `dev`, `staging`, or `prod`

```bash
# Get cluster name for substitution
CLUSTER_NAME=$(terraform output -raw cluster_name)
NODE_ROLE_NAME=$(aws iam list-instance-profiles-for-role \
  --role-name $(terraform output -json | jq -r '.nth_iam_role_arn.value' | sed 's/.*\///' | sed 's/-nth$//') \
  --query 'InstanceProfiles[0].Roles[0].RoleName' --output text 2>/dev/null || echo "CHECK_MANUALLY")

# Apply manifests (update placeholders first)
sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
    -e "s/\${NODE_ROLE_NAME}/$NODE_ROLE_NAME/g" \
    -e "s/\${ENVIRONMENT}/dev/g" \
    karpenter-nodeclass.yaml | kubectl apply -f -

kubectl apply -f karpenter-nodepool.yaml
```

### Validation

- [ ] EC2NodeClass created:
  ```bash
  kubectl get ec2nodeclass default
  ```
  Expected: `STATUS` shows `Ready`

- [ ] NodePool created:
  ```bash
  kubectl get nodepool default
  ```

- [ ] No nodes provisioned yet (taint prevents scheduling):
  ```bash
  kubectl get nodeclaim
  ```
  Expected: no resources found

---

## Step 3 — Validate Karpenter Provisioning with a Test Pod

**What:** Deploy a test pod with the migration toleration to verify end-to-end provisioning.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: karpenter-migration-test
  namespace: default
spec:
  tolerations:
    - key: karpenter.sh/migration
      value: "true"
      effect: NoSchedule
  containers:
    - name: test
      image: public.ecr.aws/amazonlinux/amazonlinux:2
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "500m"
          memory: "512Mi"
  terminationGracePeriodSeconds: 0
EOF
```

### Validation

- [ ] NodeClaim created and progressing:
  ```bash
  kubectl get nodeclaim -w
  ```
  Expected: a NodeClaim appears, transitions through `Launched` → `Registered` → `Initialized`

- [ ] New node joined the cluster:
  ```bash
  kubectl get nodes -l karpenter.sh/nodepool=default
  ```
  Expected: 1 new node in `Ready` state

- [ ] Test pod is `Running`:
  ```bash
  kubectl get pod karpenter-migration-test
  ```

- [ ] Node is a spot instance:
  ```bash
  kubectl get node -l karpenter.sh/nodepool=default \
    -o jsonpath='{.items[0].metadata.labels.karpenter\.sh/capacity-type}'
  ```
  Expected: `spot`

- [ ] Clean up test pod:
  ```bash
  kubectl delete pod karpenter-migration-test
  ```

> **🛑 STOP HERE if any validation fails.** Debug before proceeding. Common issues:
> - `AccessDenied` in Karpenter logs → check IAM policy
> - `NodeClaim` stuck in `Launched` → check subnet tags or security group tags
> - `NodeClaim` stuck → check EKS access entry for the node role

---

## Step 4 — Remove Migration Taint

**What:** Allow regular workloads to schedule on Karpenter nodes.

```bash
# Option A: Edit in-place
kubectl patch nodepool default --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/taints"}]'

# Option B: Edit the YAML file and re-apply
# Remove the taints block from karpenter-nodepool.yaml, then:
# kubectl apply -f karpenter-nodepool.yaml
```

### Validation

- [ ] NodePool no longer has the taint:
  ```bash
  kubectl get nodepool default -o jsonpath='{.spec.template.spec.taints}'
  ```
  Expected: empty or no output

- [ ] Deploy a test pod WITHOUT tolerations:
  ```bash
  cat <<'EOF' | kubectl apply -f -
  apiVersion: v1
  kind: Pod
  metadata:
    name: karpenter-schedule-test
    namespace: default
  spec:
    containers:
      - name: test
        image: public.ecr.aws/amazonlinux/amazonlinux:2
        command: ["sleep", "300"]
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
    terminationGracePeriodSeconds: 0
  EOF
  ```

- [ ] Pod scheduled on a Karpenter node:
  ```bash
  kubectl get pod karpenter-schedule-test -o wide
  ```
  Expected: running on a node with label `karpenter.sh/nodepool=default`

- [ ] Clean up:
  ```bash
  kubectl delete pod karpenter-schedule-test
  ```

---

## Step 5 — Cordon and Drain Old ASG Nodes (One at a Time)

**What:** Gracefully migrate workloads off ASG spot nodes to Karpenter nodes.

> **⚠️ CRITICAL:** Drain ONE node at a time. Wait for all pods to be healthy on new nodes before draining the next. Karpenter will automatically provision replacement capacity as pods go `Pending`.

```bash
# List ASG spot worker nodes
kubectl get nodes -l role=spot-worker

# For EACH node (one at a time):
NODE_NAME="<node-name>"

# 1. Cordon — prevent new pods from scheduling
kubectl cordon "$NODE_NAME"

# 2. Drain — evict existing pods (respects PDBs)
kubectl drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=120 \
  --timeout=300s

# 3. Wait for replacement pods to be Running
kubectl get pods --all-namespaces -o wide | grep -i pending
# Expected: no Pending pods (Karpenter provisions nodes for them)

# 4. Verify new Karpenter nodes
kubectl get nodes -l karpenter.sh/nodepool=default
```

### Validation (per node)

- [ ] All pods from the drained node are running on other nodes
- [ ] No pods in `Pending` state for more than 2 minutes
- [ ] Karpenter logs show successful provisioning
- [ ] Application health checks are passing

### Repeat for each ASG node until all are drained.

---

## Step 6 — Scale ASG to Zero

**What:** Once all workloads are running on Karpenter nodes, scale the ASG to zero.

```bash
# Get the ASG name
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?Tags[?Key=='eks:nodegroup-name' && Value=='spot_workers']].AutoScalingGroupName" \
  --output text)

echo "ASG to scale down: $ASG_NAME"

# Scale to zero
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity 0 \
  --min-size 0
```

### Validation

- [ ] No ASG instances running:
  ```bash
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances'
  ```
  Expected: `[]`

- [ ] All workloads still healthy:
  ```bash
  kubectl get pods --all-namespaces --field-selector status.phase!=Running,status.phase!=Succeeded
  ```
  Expected: no unhealthy pods

- [ ] Only system + Karpenter nodes remain:
  ```bash
  kubectl get nodes
  ```

---

## Step 7 — Observation Period (24 Hours)

**What:** Monitor for 24 hours before cleaning up old resources.

### Monitor these metrics/logs:

- [ ] Karpenter controller logs (watch for errors):
  ```bash
  kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f --tail=100
  ```

- [ ] Node churn (consolidation should stabilize after initial adjustments):
  ```bash
  kubectl get nodeclaim -w
  ```

- [ ] SQS queue processing (Karpenter should handle interruption events):
  ```bash
  aws sqs get-queue-attributes \
    --queue-url $(terraform output -raw spot_termination_sqs_queue_url) \
    --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible
  ```

- [ ] Application error rates unchanged (check Prometheus/Grafana dashboards)

- [ ] Zero-disruption window tested (confirm no disruptions between 02:00–04:00 UTC)

### Go/No-Go Decision

| Check                                  | Status |
|----------------------------------------|--------|
| All workloads running on Karpenter     | ☐      |
| No unhandled spot interruptions        | ☐      |
| Consolidation is working correctly     | ☐      |
| SQS events processed without errors   | ☐      |
| No PDB violations                      | ☐      |
| Application SLOs met for 24h          | ☐      |

**If all checks pass → proceed to Step 8**  
**If any check fails → rollback (see Rollback section below)**

---

## Step 8 — Clean Up Old Resources (Terraform)

**What:** Remove NTH, lifecycle hook, and old nodegroup from Terraform.

> **⚠️ Do NOT remove `aws_sqs_queue.node_termination` or any EventBridge rules.** Karpenter uses the same SQS queue.

### 8a. Remove NTH Helm Release

Comment out or delete `helm_release.node_termination_handler` in `node-termination-handler.tf`.

```bash
terraform plan -target=helm_release.node_termination_handler
# Confirm: only 1 resource to destroy (the NTH Helm release)
terraform apply -target=helm_release.node_termination_handler
```

### 8b. Remove ASG Lifecycle Hook

Delete `aws_autoscaling_lifecycle_hook.spot_termination` and `data.aws_autoscaling_groups.spot_workers` from `spot-termination.tf`.

```bash
terraform plan
# Confirm: only lifecycle hook and data source changes
terraform apply
```

### 8c. Remove NTH IRSA (Optional — after confirming NTH is fully removed)

Delete `module.nth_irsa` and `aws_iam_policy.nth` from `irsa.tf`.

### 8d. Remove spot_workers Nodegroup (Optional — after confirming zero instances)

Remove the `spot_workers` block from `eks_managed_node_groups` in `main.tf`.

```bash
terraform plan
# Confirm: nodegroup destruction only, no impact on running workloads
terraform apply
```

---

## Rollback Procedure

If issues are found at any step:

### Quick Rollback (Steps 1–4)

```bash
# 1. Re-add the migration taint to prevent new pods on Karpenter nodes
kubectl patch nodepool default --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/taints", "value": [{"key": "karpenter.sh/migration", "value": "true", "effect": "NoSchedule"}]}]'

# 2. Uncordon ASG nodes (if they were cordoned)
kubectl get nodes -l role=spot-worker -o name | xargs -I{} kubectl uncordon {}

# 3. Scale ASG back up
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity 3 \
  --min-size 2
```

### Full Rollback

```bash
# Remove Karpenter entirely
kubectl delete nodepool default
kubectl delete ec2nodeclass default
terraform destroy -target=helm_release.karpenter \
                  -target=aws_eks_access_entry.karpenter_node \
                  -target=aws_iam_policy.karpenter_controller \
                  -target=module.karpenter_irsa
```

---

## Post-Migration Architecture

```
Before:                              After:
┌─────────────────────┐              ┌─────────────────────┐
│    EventBridge       │              │    EventBridge       │
│  (4 rules - KEPT)   │              │  (4 rules - KEPT)   │
└────────┬────────────┘              └────────┬────────────┘
         │                                    │
         ▼                                    ▼
┌─────────────────────┐              ┌─────────────────────┐
│   SQS Queue (KEPT)  │              │   SQS Queue (KEPT)  │
└────────┬────────────┘              └────────┬────────────┘
         │                                    │
         ▼                                    ▼
┌─────────────────────┐              ┌─────────────────────┐
│   NTH (REMOVED)     │              │ Karpenter Controller │
│   polls SQS         │              │ consumes SQS events  │
└────────┬────────────┘              └────────┬────────────┘
         │                                    │
         ▼                                    ▼
┌─────────────────────┐              ┌─────────────────────┐
│  ASG spot_workers    │              │  Direct EC2 launch   │
│  (fixed instance     │              │  (any of 10 families │
│   types, slow scale) │              │   fast, bin-packed)  │
└─────────────────────┘              └─────────────────────┘
```

---

## Files Reference

| File                         | Purpose                                     |
|------------------------------|---------------------------------------------|
| `karpenter.tf`               | IRSA, IAM policy, Helm release              |
| `karpenter-nodeclass.yaml`   | EC2NodeClass (subnets, SGs, AMI, IAM)       |
| `karpenter-nodepool.yaml`    | NodePool (instance types, limits, disruption)|
| `spot-termination.tf`        | EventBridge + SQS (UNCHANGED)               |
| `node-termination-handler.tf`| NTH Helm release (REMOVE after migration)   |
| `irsa.tf`                    | NTH IRSA (REMOVE after migration)           |
