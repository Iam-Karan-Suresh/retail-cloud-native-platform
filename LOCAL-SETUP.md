# Local Kubernetes Setup Guide — Retail Cloud Native Platform

![Local Development](./docs/images/banner.png)

<div align="center">
  <strong>
  <h2>Local Development with Kind + GitLab On-Prem CI/CD</h2>
  </strong>
</div>

This guide covers how to run the entire Retail Cloud Native Platform on a **local Kubernetes cluster** using [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker), with CI/CD via **GitLab on-prem**. No AWS account or cloud dependencies required.

---

## Table of Contents

- [Architecture: Local vs AWS](#architecture-local-vs-aws)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Step-by-Step Manual Setup](#step-by-step-manual-setup)
- [Accessing the Application](#accessing-the-application)
- [Running with Stateful Backends](#running-with-stateful-backends)
- [GitLab On-Prem CI/CD Setup](#gitlab-on-prem-cicd-setup)
- [Development Workflow](#development-workflow)
- [vCluster Alternative](#vcluster-alternative)
- [What's Different from AWS](#whats-different-from-aws)
- [Troubleshooting](#troubleshooting)

---

## Architecture: Local vs AWS

The local setup replaces all AWS infrastructure with Kind-native equivalents:

```
┌──────────────────────────────────────────────────────────────────────┐
│                       LOCAL MACHINE (Kind)                           │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                    Kind Cluster (3 nodes)                      │  │
│  │                                                                │  │
│  │  ┌────────────────┐    ┌──────────────────────────────────┐   │  │
│  │  │ Control Plane   │   │ Worker Nodes (x2)                │   │  │
│  │  │                 │   │                                  │   │  │
│  │  │ Traefik (Helm)  │   │  UI (Java)                       │   │  │
│  │  │ KEDA (Helm)     │   │  Cart (Java)                     │   │  │
│  │  │ CoreDNS         │   │  Catalog (Go)                    │   │  │
│  │  │                 │   │  Orders (Java)                   │   │  │
│  │  │                 │   │  Checkout (Node.js)              │   │  │
│  │  └────────────────┘   └──────────────────────────────────┘   │  │
│  │                                                                │  │
│  │  Port Mapping: localhost:80 → Traefik NodePort                │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌──────────┐  ┌──────────────┐  ┌─────────────────────────────┐    │
│  │ Docker   │  │ GitLab Runner│  │ GitLab On-Prem (CI/CD)      │    │
│  │ Engine   │  │ (Shell/Docker│  │ Container Registry          │    │
│  │          │  │  Executor)   │  │ Helm Registry               │    │
│  └──────────┘  └──────────────┘  └─────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

| Component | AWS (Production) | Local (Kind) |
|-----------|-----------------|--------------|
| **Cluster** | EKS via Terraform | Kind via `local/setup.sh` |
| **Ingress** | Traefik + AWS NLB | Traefik + NodePort (localhost:80) |
| **Autoscaling** | KEDA + Karpenter (Spot) | KEDA (optional), no Karpenter |
| **CD** | ~~ArgoCD~~ → Direct Helm | Direct Helm via CI/CD |
| **Monitoring** | Prometheus/Grafana (EKS Addons) | Prometheus/Grafana (Kustomize) |
| **DNS/TLS** | Route53 + Cert-Manager + Let's Encrypt | localhost (no TLS) |
| **Node Scheduling** | System (On-Demand) + Spot workers | No scheduling constraints |

---

## Prerequisites

### Required Tools

| Tool | Version | Installation |
|------|---------|-------------|
| **Docker** | 20.0+ | [Install Guide](https://docs.docker.com/get-docker/) |
| **Kind** | 0.20+ | [Install Guide](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| **kubectl** | 1.28+ | [Install Guide](https://kubernetes.io/docs/tasks/tools/) |
| **Helm** | 3.14+ | [Install Guide](https://helm.sh/docs/intro/install/) |
| **Git** | 2.0+ | [Install Guide](https://git-scm.com/downloads) |

### System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **CPU** | 4 cores | 8 cores |
| **RAM** | 8 GB | 16 GB |
| **Disk** | 20 GB free | 40 GB free |
| **Docker** | Running with 6+ GB allocated | 10+ GB allocated |

<details>
<summary><strong>🔧 One-Click Installation (Linux)</strong></summary>

```bash
#!/bin/bash
# Install all prerequisites for local development

# Docker
curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
sudo usermod -aG docker $USER && newgrp docker

# Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
docker --version && kind --version && kubectl version --client && helm version
```

</details>

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://your-gitlab-server/your-group/retail-cloud-native-platform.git
cd retail-cloud-native-platform

# 2. Run the automated setup (creates cluster + deploys everything)
./local/setup.sh

# 3. Open the retail store in your browser
open http://localhost
# or: curl http://localhost
```

That's it. The setup script handles:
1. ✅ Creating a 3-node Kind cluster
2. ✅ Installing Gateway API CRDs
3. ✅ Installing Traefik (ingress controller)
4. ✅ Installing KEDA (event-driven autoscaling)
5. ✅ Deploying observability stack (Prometheus, Grafana, Loki, Tempo)
6. ✅ Deploying all 5 microservices

### Teardown

```bash
# Delete the entire cluster
./local/teardown.sh

# Or just remove the apps (keep cluster running)
./local/teardown.sh --apps-only
```

---

## Step-by-Step Manual Setup

If you prefer to understand each step:

### Step 1: Create the Kind Cluster

```bash
kind create cluster --config local/kind-cluster.yaml --wait 120s
```

This creates a 3-node cluster:
- 1 control-plane with port mappings (80, 443 on host)
- 2 worker nodes

Verify:
```bash
kubectl get nodes
# NAME                               STATUS   ROLES           AGE   VERSION
# retail-store-local-control-plane   Ready    control-plane   30s   v1.31.x
# retail-store-local-worker          Ready    <none>          20s   v1.31.x
# retail-store-local-worker2         Ready    <none>          20s   v1.31.x
```

### Step 2: Install Gateway API CRDs

Traefik needs Gateway API CRDs before it can start:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

### Step 3: Install Traefik

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm upgrade --install traefik traefik/traefik \
  --version 40.0.0 \
  --namespace traefik-system \
  --create-namespace \
  --set providers.kubernetesGateway.enabled=true \
  --set providers.kubernetesIngress.enabled=false \
  --set service.type=NodePort \
  --set "service.nodePorts.web=30080" \
  --set "service.nodePorts.websecure=30443" \
  --set deployment.replicas=1 \
  --wait --timeout 5m
```

### Step 4: Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm upgrade --install keda kedacore/keda \
  --version 2.19.0 \
  --namespace keda \
  --create-namespace \
  --wait --timeout 5m
```

### Step 5: Deploy Observability Stack

```bash
# Create Grafana credentials (if not exists)
mkdir -p k8s/observability/configs
cat > k8s/observability/configs/grafana-admin-credentials.env << EOF
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=admin
EOF

kubectl apply -k k8s/observability
```

### Step 6: Deploy Microservices

```bash
# Create namespace
kubectl create namespace retail-store

# Deploy each service with local values
for service in catalog cart orders checkout ui; do
  helm upgrade --install "retail-store-${service}" \
    "./src/${service}/chart" \
    --namespace retail-store \
    -f "local/values/${service}-local.yaml" \
    --timeout 5m --wait
done
```

Or use the deploy script:
```bash
./deploy.sh --local
```

### Step 7: Verify

```bash
kubectl get pods -n retail-store
kubectl get svc -n retail-store
kubectl get gateway -n retail-store
kubectl get httproute -n retail-store
```

---

## Accessing the Application

### Retail Store UI

```
http://localhost
```

The Kind cluster maps port 80 on your host to Traefik's NodePort. Traefik routes traffic to the UI service via the Gateway API HTTPRoute.

### Port Forwarding (Alternative)

If port mapping isn't working, use kubectl port-forward:

```bash
# UI Service directly
kubectl port-forward -n retail-store svc/retail-store-ui 8080:80 &
# Open: http://localhost:8080

# Traefik Dashboard
kubectl port-forward -n traefik-system svc/traefik 9000:9000 &
# Open: http://localhost:9000/dashboard/

# Grafana
kubectl port-forward -n observability svc/grafana 3000:3000 &
# Open: http://localhost:3000 (admin/admin)
```

---

## Running with Stateful Backends

By default, all services run with **in-memory** data stores (no databases needed). To deploy with real databases:

```bash
# Automated
./local/setup.sh --stateful

# Or manual
./deploy.sh --local --stateful
```

This enables:

| Service | Backend | What's Deployed |
|---------|---------|----------------|
| **Cart** | DynamoDB Local | DynamoDB Local container in-cluster |
| **Catalog** | MySQL 8.4 | MySQL StatefulSet in-cluster |
| **Checkout** | Redis 8 | Redis StatefulSet in-cluster |
| **Orders** | PostgreSQL 16 + RabbitMQ 4.2 | PostgreSQL + RabbitMQ StatefulSets |

> **Note:** In stateful mode, KEDA is also enabled for the Orders service, scaling based on RabbitMQ queue depth.

---

## GitLab On-Prem CI/CD Setup

### Overview

The CI/CD pipeline runs on your GitLab on-prem instance. Since the GitLab Runner is on the **same machine** as the Kind cluster, it has direct kubectl/helm access.

```
Developer → git push → GitLab On-Prem → Runner (same machine) → Kind Cluster
```

### Step 1: Install GitLab Runner

```bash
# Download and install GitLab Runner
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash
sudo apt-get install gitlab-runner
```

### Step 2: Register the Runner

```bash
sudo gitlab-runner register \
  --url "https://your-gitlab-server" \
  --registration-token "YOUR_REGISTRATION_TOKEN" \
  --description "local-k8s-runner" \
  --tag-list "docker,local,kind" \
  --executor "docker" \
  --docker-image "alpine:latest" \
  --docker-privileged=true \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock"
```

> **Important:** Use `--executor docker` with Docker socket mounting so the runner can build images and access the Kind cluster network.

### Step 3: Configure CI/CD Variables

In GitLab UI: **Settings → CI/CD → Variables**

| Variable | Value | Flags |
|----------|-------|-------|
| `KUBECONFIG_LOCAL` | `base64 -w0 ~/.kube/config` | Protected, Masked |

Generate the kubeconfig:
```bash
# Get the Kind kubeconfig and base64 encode it
kind get kubeconfig --name retail-store-local | base64 -w0
# Copy the output and set it as KUBECONFIG_LOCAL in GitLab
```

### Step 4: Configure Container Registry

GitLab on-prem includes a built-in container registry. The CI pipeline is already configured to push to `${CI_REGISTRY_IMAGE}/<service>`.

For Kind to pull images from the GitLab registry:

```bash
# Create a Docker registry secret in the retail-store namespace
kubectl create secret docker-registry gitlab-registry \
  --docker-server=your-gitlab-server:5050 \
  --docker-username=your-username \
  --docker-password=your-access-token \
  --namespace retail-store
```

Then reference it in the local values or set `imagePullSecrets` via Helm:
```bash
helm upgrade --install retail-store-ui ./src/ui/chart \
  -f local/values/ui-local.yaml \
  --set "imagePullSecrets[0].name=gitlab-registry" \
  -n retail-store
```

### Step 5: Pipeline Overview

The pipeline runs automatically on push to `main`:

```
preflight → security → lint → test → build → scan → publish-chart
                                                       ↓
                              deploy-staging → integration-test
                                                       ↓
                              deploy-production (manual gate)
                                                       ↓
                              deploy-local (auto on main)
                                                       ↓
                              smoke-test-local → notify
```

**Key stages for local:**
- **build**: Builds Docker images via Kaniko, pushes to GitLab Container Registry
- **deploy-local**: Deploys to Kind cluster with local values overrides
- **smoke-test-local**: Validates pods are ready and UI is accessible

---

## Development Workflow

### Build and Load Images Locally (No Registry)

For fast iteration, skip the registry and load images directly into Kind:

```bash
# Build a service image locally
cd src/ui
docker build -t retail-store-sample-ui:dev .

# Load it into Kind
kind load docker-image retail-store-sample-ui:dev --name retail-store-local

# Deploy with the local image
helm upgrade --install retail-store-ui ./chart \
  -n retail-store \
  -f ../../local/values/ui-local.yaml \
  --set image.repository=retail-store-sample-ui \
  --set image.tag=dev \
  --set image.pullPolicy=Never
```

### Hot Reload Workflow

```bash
# 1. Make code changes
# 2. Rebuild the image
docker build -t retail-store-sample-ui:dev .

# 3. Load into Kind
kind load docker-image retail-store-sample-ui:dev --name retail-store-local

# 4. Restart the deployment to pick up the new image
kubectl rollout restart deployment/retail-store-ui -n retail-store

# 5. Watch the rollout
kubectl rollout status deployment/retail-store-ui -n retail-store
```

### Useful Commands

```bash
# View all pods across all namespaces
kubectl get pods -A

# View app pods
kubectl get pods -n retail-store -o wide

# View logs for a service
kubectl logs -n retail-store -l app.kubernetes.io/instance=retail-store-ui --tail=50 -f

# Describe a failing pod
kubectl describe pod -n retail-store <pod-name>

# Shell into a pod
kubectl exec -it -n retail-store deployment/retail-store-ui -- sh

# View Helm releases
helm list -n retail-store

# Check Traefik routing
kubectl get gateway,httproute -n retail-store
```

---

## vCluster Alternative

If you prefer [vCluster](https://www.vcluster.com/) over Kind (e.g., you already have a host Kubernetes cluster):

```bash
# Install vCluster CLI
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64"
chmod +x vcluster && sudo mv vcluster /usr/local/bin/

# Create a vCluster
vcluster create retail-store-local --namespace vcluster-retail

# Connect to the vCluster
vcluster connect retail-store-local --namespace vcluster-retail

# Now deploy as usual
./deploy.sh --local

# Disconnect
vcluster disconnect

# Delete
vcluster delete retail-store-local --namespace vcluster-retail
```

> **Note:** vCluster doesn't support port mappings like Kind. You'll need to use `kubectl port-forward` to access services, or set up an ingress on the host cluster.

---

## What's Different from AWS

| Feature | AWS (Production) | Local (Kind) | Impact |
|---------|-----------------|--------------|--------|
| **Node Types** | System (On-Demand) + Spot Workers | Generic Kind nodes | No `nodeSelector` or `tolerations` |
| **Karpenter** | Dynamic spot provisioning | Not available | N/A — Kind has fixed nodes |
| **Topology Spread** | Cross-AZ spread | Disabled | Only 1 "zone" locally |
| **PDB** | Enabled (minAvailable: 2-3) | Disabled | Only 1 replica locally |
| **Replicas** | 3-4 per service | 1 per service | Save local resources |
| **Load Balancer** | AWS NLB | NodePort → localhost:80 | Access via `http://localhost` |
| **TLS/Cert-Manager** | Let's Encrypt via ACME | Disabled | No domain needed |
| **ArgoCD** | ~~GitOps sync~~ | Not used | Direct Helm deploy only |
| **EventBridge/SQS** | Spot interruption pipeline | Not needed | No spot instances |
| **IRSA** | IAM Roles for Service Accounts | Not needed | No AWS API calls |
| **OpenTelemetry** | Enabled → OTel Collector | Disabled by default | Enable manually if needed |

---

## Troubleshooting

### Kind Cluster Won't Start

```bash
# Check Docker is running
docker info

# Check for port conflicts (80, 443)
sudo lsof -i :80
sudo lsof -i :443

# Delete and recreate
kind delete cluster --name retail-store-local
./local/setup.sh
```

### Pods Stuck in Pending

```bash
# Check node resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check events
kubectl get events -n retail-store --sort-by='.lastTimestamp'

# Reduce resource requests in local values if needed
```

### Pods in ImagePullBackOff

```bash
# If using GitLab registry, ensure the pull secret exists
kubectl get secret gitlab-registry -n retail-store

# If using local images, load them into Kind first
kind load docker-image <image:tag> --name retail-store-local

# Check image pull policy is correct
kubectl describe pod <pod-name> -n retail-store | grep -A 2 "Image:"
```

### Traefik Not Routing Traffic

```bash
# Check Traefik pods
kubectl get pods -n traefik-system

# Check Gateway resource
kubectl get gateway -n retail-store
kubectl describe gateway -n retail-store

# Check HTTPRoute
kubectl get httproute -n retail-store
kubectl describe httproute -n retail-store

# Check Traefik logs
kubectl logs -n traefik-system -l app.kubernetes.io/name=traefik --tail=50
```

### Port 80 Already in Use

```bash
# Find what's using port 80
sudo lsof -i :80

# Stop the conflicting service (e.g., nginx, apache)
sudo systemctl stop nginx

# Or change the Kind port mapping in local/kind-cluster.yaml:
# hostPort: 8080  (then access via http://localhost:8080)
```

### Services Can't Communicate

```bash
# Verify DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup retail-store-catalog.retail-store.svc.cluster.local

# Check service endpoints
kubectl get endpoints -n retail-store

# Check configmap for service URLs
kubectl get configmap -n retail-store -o yaml
```

### Reset Everything

```bash
# Nuclear option — delete cluster and start over
./local/teardown.sh
./local/setup.sh
```

---

## Project Structure (Local Files)

```
retail-cloud-native-platform/
├── local/                              # ← NEW: Local deployment tooling
│   ├── kind-cluster.yaml               # Kind cluster configuration (3 nodes)
│   ├── setup.sh                        # One-shot bootstrap script
│   ├── teardown.sh                     # Cluster teardown script
│   ├── values-local-stateful.yaml      # Stateful overlay (databases in-cluster)
│   └── values/                         # Per-service local value overrides
│       ├── ui-local.yaml               # UI: no nodeSelector, 1 replica, no TLS
│       ├── cart-local.yaml             # Cart: in-memory, no AWS scheduling
│       ├── catalog-local.yaml          # Catalog: in-memory, no AWS scheduling
│       ├── checkout-local.yaml         # Checkout: in-memory, no AWS scheduling
│       └── orders-local.yaml           # Orders: in-memory, KEDA disabled
│
├── .gitlab-ci.yml                      # Updated: removed ArgoCD, added deploy-local
├── .gitlab/ci/
│   ├── deploy-local.yml                # ← NEW: Local Kind deployment stage
│   ├── deploy-staging.yml              # Updated: direct Helm deploy
│   ├── deploy-production.yml           # Updated: removed ArgoCD sync strategy
│   └── publish-chart.yml              # Updated: removed GitOps commit-back
│
├── deploy.sh                           # Updated: --local and --stateful flags
├── LOCAL-SETUP.md                      # ← NEW: This document
│
├── src/                                # Application source + Helm charts (unchanged)
├── terraform/                          # AWS IaC (unchanged — not used locally)
├── argocd/                             # ArgoCD manifests (preserved for reference)
└── k8s/observability/                  # Observability stack (works as-is)
```

---

<div align="center">

**🏠 Happy Local Development!**

If you hit issues, check the [Troubleshooting](#troubleshooting) section or open an issue.

</div>
