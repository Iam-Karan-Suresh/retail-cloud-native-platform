# Retail Cloud-Native Platform — Production-Grade EKS with Karpenter

![Banner](./docs/images/banner.png)

<div align="center">
  <strong>
  <h2>AWS Containers Retail Sample</h2>
  </strong>
</div>

A production-grade retail store application deployed on AWS EKS with Karpenter-based spot instance provisioning, GitOps via ArgoCD, and full observability. This project demonstrates how to build a cost-optimized, highly available microservices platform using modern cloud-native tooling.

---

## Table of Contents

- [How It Works (The Big Picture)](#how-it-works-the-big-picture)
- [Application Architecture](#application-architecture)
- [Infrastructure Architecture](#infrastructure-architecture)
- [Workload Placement & Spot Optimization](#workload-placement--spot-optimization)
- [What Happens When a Spot Instance Gets Reclaimed?](#what-happens-when-a-spot-instance-gets-reclaimed)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Step-by-Step Deployment](#step-by-step-deployment)
- [Accessing the Application](#accessing-the-application)
- [GitOps with ArgoCD](#gitops-with-argocd)
- [Custom Domain Setup (Optional)](#custom-domain-setup-optional)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## How It Works (The Big Picture)

If you're new to this project, here's the 30-second version:

```
You (browser) → AWS Load Balancer → Traefik Gateway → Microservices on EKS
                                                         │
                                     ┌───────────────────┤
                                     │                   │
                              System Nodes          Karpenter Nodes
                              (On-Demand)           (Spot — 70-80% cheaper)
                              ┌──────────┐          ┌────────────────────┐
                              │ Traefik  │          │ UI (Java)          │
                              │ ArgoCD   │          │ Cart (Java)        │
                              │ Karpenter│          │ Catalog (Go)       │
                              │ KEDA     │          │ Orders (Java)      │
                              │ Prom/Graf│          │ Checkout (Node.js) │
                              └──────────┘          └────────────────────┘
```

1. **Terraform** creates the VPC, EKS cluster, and installs all the tooling (Karpenter, Traefik, ArgoCD, monitoring).
2. **Karpenter** dynamically provisions EC2 instances when pods need capacity — it picks the cheapest spot instance from 50+ candidates.
3. **ArgoCD** watches your Git repo and automatically deploys any Kubernetes manifest changes.
4. **Traefik** routes incoming HTTP traffic to the right microservice using the Gateway API.
5. When AWS reclaims a spot instance, **Karpenter** catches the 2-minute warning, launches a replacement node, and drains workloads — zero downtime.

---

## Application Architecture

The application is a retail store with 5 microservices. Each service is independently deployable and has its own Helm chart.

![Architecture](https://github.com/aws-containers/retail-store-sample-app/raw/main/docs/images/architecture.png)

| Component | Language | What It Does | Runs On |
|-----------|----------|-------------|---------|
| [UI](./src/ui/) | Java | Store frontend — renders pages, proxies API calls | Karpenter (Spot) |
| [Catalog](./src/catalog/) | Go | Product catalog API — list/search products | Karpenter (Spot) |
| [Cart](./src/cart/) | Java | Shopping cart API — add/remove items | Karpenter (Spot) |
| [Orders](./src/orders/) | Java | Order management API — place/track orders | Karpenter (Spot) |
| [Checkout](./src/checkout/) | Node.js | Checkout orchestration — coordinates the purchase flow | Karpenter (Spot) |

**Why these run on spot:** All 5 services are **stateless** — they hold no local data. If a node dies, the pods restart on another node and continue serving requests. The databases (MySQL, Redis, RabbitMQ) run on **On-Demand system nodes** where they're never interrupted.

---

## Infrastructure Architecture

The infrastructure follows a **split compute strategy** to balance cost and reliability:

```
┌──────────────────────────────────────────────────────────────────────┐
│                          AWS Account                                  │
│                                                                       │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │                    VPC (3 Availability Zones)                    │   │
│  │                                                                  │   │
│  │  ┌─────────────┐   ┌──────────────────────────────────────┐     │   │
│  │  │ Public       │   │ Private Subnets                       │     │   │
│  │  │ Subnets      │   │                                       │     │   │
│  │  │ ┌─────┐      │   │  ┌────────────┐  ┌────────────────┐  │     │   │
│  │  │ │ NLB │──────┼──▶│  │ System     │  │ Karpenter      │  │     │   │
│  │  │ └─────┘      │   │  │ Nodes      │  │ Nodes          │  │     │   │
│  │  │ ┌─────┐      │   │  │ (On-Demand)│  │ (Spot/OD mix)  │  │     │   │
│  │  │ │ NAT │      │   │  │            │  │                │  │     │   │
│  │  │ │ GW  │      │   │  │ Traefik    │  │ UI, Cart,      │  │     │   │
│  │  │ └─────┘      │   │  │ ArgoCD     │  │ Catalog,       │  │     │   │
│  │  └─────────────┘   │  │ Karpenter  │  │ Orders,        │  │     │   │
│  │                      │  │ Prometheus │  │ Checkout       │  │     │   │
│  │                      │  │ KEDA       │  │                │  │     │   │
│  │                      │  └────────────┘  └────────────────┘  │     │   │
│  │                      └──────────────────────────────────────┘     │   │
│  └────────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  ┌────────────┐  ┌──────────┐  ┌───────────┐  ┌─────────────────┐    │
│  │ EventBridge│─▶│ SQS      │─▶│ Karpenter │  │ EKS Control     │    │
│  │ (4 rules)  │  │ Queue    │  │ Controller│  │ Plane (managed) │    │
│  └────────────┘  └──────────┘  └───────────┘  └─────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Why |
|----------|-----|
| **Karpenter instead of Cluster Autoscaler** | Direct EC2 provisioning = faster scaling, better bin-packing, native spot handling |
| **Traefik instead of NGINX Ingress** | Gateway API is the Kubernetes-native successor to Ingress — portable, role-oriented |
| **KEDA instead of HPA** | Scales on queue depth (leading indicator) not CPU (lagging indicator) |
| **ArgoCD instead of CI-driven deploys** | GitOps = declarative, auditable, self-healing deployments |
| **EventBridge → SQS pipeline** | Decouples AWS events from the consumer — works with both NTH and Karpenter |

---

## Workload Placement & Spot Optimization

### 🚀 Karpenter Nodes (Spot-Preferred)
*Stateless services that can handle interruption.*
- **UI, Catalog, Cart, Orders, Checkout** — all have multiple replicas spread across AZs
- **Pod Disruption Budgets (PDBs)** — guarantee minimum replicas during drains
- **Topology Spread Constraints** — ensure replicas are in different AZs
- **10 Instance Families** — m5, m5a, m5d, m6i, m6a, m4, r5, r6i, c5, c6i
- **Automatic consolidation** — underutilized nodes are replaced with right-sized ones

### 🛡️ System Nodes (On-Demand)
*Critical infrastructure that must never be interrupted.*
- **Cluster operators:** ArgoCD, Cert-Manager, Traefik Gateway, KEDA, Karpenter itself
- **Monitoring:** Prometheus + Grafana
- **Taint:** `CriticalAddonsOnly=true:NoSchedule` — prevents app pods from landing here

| Component | Node Type | Why |
|-----------|-----------|-----|
| **Stateless APIs** | **Spot (Karpenter)** | 70–80% cost savings, auto-replaced on interruption |
| **Traefik / ArgoCD / KEDA** | **On-Demand (System)** | Must never be interrupted — routing / deployment critical |
| **Karpenter Controller** | **On-Demand (System)** | If Karpenter itself is on spot, who provisions the replacement? |
| **Monitoring** | **On-Demand (System)** | Need visibility even during spot disruption events |

---

## What Happens When a Spot Instance Gets Reclaimed?

This is the most important thing to understand. Here's the timeline:

```
T-120s  AWS sends "Spot Interruption Warning" to EventBridge
T-119s  EventBridge forwards to SQS queue
T-118s  Karpenter picks up the message from SQS
T-117s  Karpenter launches a replacement node (picks cheapest spot from 50+ candidates)
T-115s  Karpenter cordons the affected node (no new pods scheduled)
T-110s  Karpenter drains the node — pods get SIGTERM, finish requests, shut down gracefully
T-80s   Drained pods are rescheduled on the replacement node (already booted)
T-0s    AWS reclaims the instance — workloads were safe 60+ seconds ago
```

**Result:** Zero dropped connections. Users don't notice anything.

For the full deep-dive, see [SPOT-ARCHITECTURE-GUIDE.md](./SPOT-ARCHITECTURE-GUIDE.md).

---

## Project Structure

```
retail-cloud-native-platform/
├── terraform/                      # All infrastructure as code
│   ├── main.tf                     # VPC, EKS cluster, node groups
│   ├── karpenter.tf                # Karpenter IRSA, IAM policy, Helm release
│   ├── karpenter-nodeclass.yaml    # EC2NodeClass — how nodes are configured
│   ├── karpenter-nodepool.yaml     # NodePool — what Karpenter can provision
│   ├── spot-termination.tf         # EventBridge → SQS pipeline
│   ├── addons.tf                   # Cert-Manager, Prometheus, Traefik, KEDA
│   ├── argocd.tf                   # ArgoCD Helm release
│   ├── security.tf                 # Security group rules
│   ├── locals.tf                   # Common tags, network CIDRs
│   ├── variables.tf                # Input variables
│   ├── outputs.tf                  # Cluster endpoint, SQS URL, etc.
│   ├── versions.tf                 # Provider versions
│   ├── ARCHITECTURE.md             # Infrastructure architecture diagram
│   └── migration-checklist.md      # ASG→Karpenter migration runbook
│
├── src/                            # Application source code + Helm charts
│   ├── ui/                         # Java/Spring Boot frontend
│   │   ├── chart/                  # Helm chart (values.yaml, templates/)
│   │   ├── Dockerfile
│   │   └── src/
│   ├── catalog/                    # Go product catalog API
│   ├── cart/                       # Java shopping cart API
│   ├── orders/                     # Java order management API
│   └── checkout/                   # Node.js checkout orchestration API
│
├── argocd/                         # ArgoCD application manifests
│   ├── applications/               # ArgoCD Application CRDs
│   └── projects/                   # ArgoCD AppProject CRDs
│
├── k8s/                            # Additional Kubernetes manifests
│   ├── monitoring/                 # Monitoring configs (dashboards, alerts)
│   └── spot-resilience/            # PDBs, topology spread configs
│
├── SPOT-ARCHITECTURE-GUIDE.md      # Deep-dive on spot architecture + interview prep
├── migration-guide.md              # General migration documentation
└── README.md                       # ← You are here
```

---

## Prerequisites

### Required Tools

| Tool | Version | Installation |
|------|---------|-------------|
| **AWS CLI** | v2+ | [Install Guide](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| **Terraform** | 1.0+ | [Install Guide](https://developer.hashicorp.com/terraform/install) |
| **kubectl** | 1.31+ | [Install Guide](https://kubernetes.io/docs/tasks/tools/) |
| **Docker** | 20.0+ | [Install Guide](https://docs.docker.com/get-docker/) |
| **Helm** | 3.0+ | [Install Guide](https://helm.sh/docs/intro/install/) |
| **Git** | 2.0+ | [Install Guide](https://git-scm.com/downloads) |

<details>
<summary><strong>🔧 One-Click Installation (Linux)</strong></summary>

```bash
#!/bin/bash
# Install all prerequisites

# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Terraform
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Docker
curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
aws --version && terraform --version && kubectl version --client && docker --version && helm version
```

</details>

---

## Quick Start

```bash
# 1. Configure AWS credentials
aws configure

# 2. Clone the repo
git clone https://github.com/iam-Karan-Suresh/retail-cloud-native-platform.git
cd retail-cloud-native-platform/terraform

# 3. Phase 1 — Create VPC + EKS cluster (takes ~15 minutes)
terraform init
terraform apply -target=module.vpc -target=module.retail_app_eks --auto-approve

# 4. Update kubeconfig
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region $(terraform output -raw aws_region 2>/dev/null || echo "us-west-2")

# 5. Phase 2 — Deploy everything else (Karpenter, Traefik, ArgoCD, monitoring)
terraform apply --auto-approve

# 6. Get the application URL
kubectl get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

---

## Step-by-Step Deployment

### Step 1: Configure AWS Credentials

```bash
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-west-2), Output format (json)
```

### Step 2: Clone the Repository

```bash
git clone https://github.com/iam-Karan-Suresh/retail-cloud-native-platform.git
cd retail-cloud-native-platform/terraform
```

### Step 3: Phase 1 — Create EKS Cluster

This creates the VPC, subnets, EKS cluster, and node groups. Takes ~15 minutes.

```bash
terraform init
terraform apply -target=module.vpc -target=module.retail_app_eks --auto-approve
```

**What this creates:**
- VPC with 3 public + 3 private subnets across 3 AZs
- EKS cluster with managed control plane
- System node group (On-Demand, 2 nodes)
- Spot worker node group (for initial bootstrap — Karpenter replaces this)

### Step 4: Update kubeconfig

```bash
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region us-west-2
```

Verify cluster access:
```bash
kubectl get nodes
# Should show 4-5 nodes (2 system + 2-3 spot workers)
```

### Step 5: Phase 2 — Deploy All Add-ons

```bash
terraform apply --auto-approve
```

**What this deploys:**
- ✅ **Karpenter** — dynamic spot node provisioning
- ✅ **Traefik** — Gateway API traffic routing
- ✅ **ArgoCD** — GitOps continuous delivery
- ✅ **Prometheus + Grafana** — monitoring & dashboards
- ✅ **KEDA** — event-driven pod autoscaling
- ✅ **Cert-Manager** — TLS certificate management
- ✅ **EventBridge → SQS** — spot interruption pipeline

### Step 6: Apply Karpenter Manifests

```bash
# Get cluster name for variable substitution
CLUSTER_NAME=$(terraform output -raw cluster_name)

# Apply EC2NodeClass (how nodes are configured)
sed "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g; s/\${NODE_ROLE_NAME}/REPLACE_ME/g; s/\${ENVIRONMENT}/dev/g" \
  karpenter-nodeclass.yaml | kubectl apply -f -

# Apply NodePool (what Karpenter can provision)
kubectl apply -f karpenter-nodepool.yaml
```

### Step 7: Verify Everything Is Running

```bash
# Karpenter controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# Traefik gateway
kubectl get pods -n traefik-system

# ArgoCD
kubectl get pods -n argocd

# Karpenter node claims (if pods are pending)
kubectl get nodeclaim
```

---

## Accessing the Application

### Via Load Balancer (Default)

```bash
# Get the Traefik LoadBalancer URL
kubectl get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open the hostname in your browser to access the retail store.

### ArgoCD Dashboard

```bash
# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Port-forward to ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

Open https://localhost:8080 — Username: `admin`, Password: from above command.

---

## GitOps with ArgoCD

ArgoCD watches the Git repository and automatically syncs Kubernetes manifests:

1. Push a change to `src/ui/chart/values.yaml` (e.g., bump `replicaCount: 4` → `5`)
2. ArgoCD detects the drift within 3 minutes
3. ArgoCD applies the change to the cluster
4. Karpenter provisions a new node if needed
5. New pod starts on the Karpenter node

### Branch Strategy

| Branch | Purpose | Images | Deployment |
|--------|---------|--------|------------|
| **main** | Simple deployment | Public ECR (v1.2.2) | Manual |
| **production** | Full CI/CD pipeline | Private ECR (commit hashes) | Automated via GitHub Actions |

For CI/CD setup, see [BRANCHING_STRATEGY.md](./BRANCHING_STRATEGY.md) (if applicable).

---

## Custom Domain Setup (Optional)

By default, the application is accessible via the AWS ELB DNS name (e.g., `a1b2c3-xyz.elb.amazonaws.com`). If you own a domain and want HTTPS:

### Step 1: Point Your Domain to the ELB

Create a CNAME record in your DNS provider:
```
retail-store.yourdomain.com → <ELB hostname from kubectl get svc>
```

### Step 2: Enable TLS in values.yaml

Edit `src/ui/chart/values.yaml`:
```yaml
gatewayAPI:
  enabled: true
  hostname: "retail-store.yourdomain.com"
  tls:
    enabled: true
    hostname: "retail-store.yourdomain.com"
    secretName: "tls-secret"
  certManager:
    enabled: true
```

### Step 3: Re-deploy

```bash
helm upgrade retail-store-ui ./src/ui/chart -f src/ui/chart/values.yaml
```

Cert-Manager will automatically issue a Let's Encrypt certificate for your domain.

> **⚠️ Important:** Do NOT set a hostname you don't own. Cert-manager will fail to validate the domain (ACME challenge fails), and Traefik will reject traffic that doesn't match the hostname header. Leave hostname empty for ELB-only access.

---

## Cleanup

To destroy all resources:

```bash
cd terraform/

# Step 1: Remove Karpenter manifests first
kubectl delete nodepool default
kubectl delete ec2nodeclass default

# Step 2: Destroy Terraform (reverse order)
terraform destroy --auto-approve
```

> **Note:** ECR Repositories must be deleted manually from the AWS Console.

---

## Troubleshooting

### Common Issues

#### Pods Stuck in Pending
```bash
# Check if Karpenter is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# Check Karpenter logs for errors
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50

# Check NodePool exists
kubectl get nodepool

# Check for resource limit exhaustion
kubectl describe nodepool default
```

#### Karpenter Can't Provision Nodes
Common causes:
1. **IAM permissions** — check for `AccessDenied` in Karpenter logs
2. **Subnet tags** — subnets must have `kubernetes.io/cluster/<name>=shared`
3. **Security group tags** — SGs must have `eks:cluster-name=<name>`
4. **Resource limits** — NodePool may have hit 1000 vCPU / 4000Gi limit

#### TLS Certificate Not Issued
```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager --tail=20

# Check certificate status
kubectl get certificate -A
```
**Most common cause:** Hostname is set to a domain you don't own. Set `tls.enabled: false` and leave `hostname: ""` for ELB-only access.

#### Image Pull Errors
- **Public images:** Verify you're on the `main` branch with public ECR images
- **Private images:** Check GitHub Actions completed successfully, verify ECR permissions

### Getting Help

- **Architecture questions:** See [SPOT-ARCHITECTURE-GUIDE.md](./SPOT-ARCHITECTURE-GUIDE.md)
- **Terraform file map:** See [terraform/ARCHITECTURE.md](./terraform/ARCHITECTURE.md)
- **Migration from NTH:** See [terraform/migration-checklist.md](./terraform/migration-checklist.md)
- **Infrastructure issues:** Check Terraform logs and Karpenter controller logs
- **Application issues:** Check ArgoCD UI and `kubectl logs`

---

<div align="center">

**⭐ Star this repository if you found it helpful!**

</div>
