# Argo Rollouts Guide

## Overview

This project uses **Argo Rollouts** for progressive delivery with automated canary analysis. Each microservice deployment is managed as a `Rollout` resource that progressively shifts traffic from the stable version to the canary, running automated analysis at each step.

## Strategy: Progressive Canary

```
┌──────────────────────────────────────────────────────────────┐
│                    Canary Deployment Flow                     │
│                                                              │
│  Step 1: 20% canary traffic                                 │
│     └─▶ Pause 60s                                           │
│     └─▶ Run AnalysisTemplate (success-rate, latency, etc.)  │
│                                                              │
│  Step 2: 40% canary traffic                                 │
│     └─▶ Pause 60s                                           │
│     └─▶ Run AnalysisTemplate                                │
│                                                              │
│  Step 3: 80% canary traffic                                 │
│     └─▶ Pause 60s                                           │
│     └─▶ Run AnalysisTemplate                                │
│                                                              │
│  Step 4: 100% → Promote canary to stable                    │
│                                                              │
│  ❌ Any analysis failure → Automatic rollback               │
└──────────────────────────────────────────────────────────────┘
```

## AnalysisTemplate Metrics

The shared `canary-analysis` AnalysisTemplate evaluates 4 metrics from Prometheus (fed by OTel):

| Metric | Query Source | Success Condition | Failure Limit |
|--------|-------------|-------------------|---------------|
| **Success Rate** | `http_server_request_duration_seconds_count` | 5xx error rate ≤ 1% | 3 consecutive failures |
| **P95 Latency** | `http_server_request_duration_seconds_bucket` | P95 ≤ 500ms | 3 consecutive failures |
| **Memory Saturation** | `container_memory_working_set_bytes` | Usage < 90% of limit | 2 consecutive failures |
| **Pod Availability** | `kube_deployment_status_replicas_available` | ≥ 1 ready pod | 2 consecutive failures |

## Manifests

### Directory Structure
```
k8s/argo-rollouts/
├── analysis-template.yaml    # Shared AnalysisTemplate (all services)
└── checkout-rollout.yaml     # Checkout Rollout + canary/stable Services
```

### Creating Rollouts for Other Services

To convert another service (e.g., catalog), copy the checkout-rollout.yaml and modify:
1. Change `metadata.name` and all label references
2. Update `image` to the correct container image
3. Update environment variables for the specific service
4. Adjust `resources` and health check paths as needed

## Prerequisites

### Install Argo Rollouts Controller
```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

### Install Argo Rollouts kubectl Plugin
```bash
brew install argoproj/tap/kubectl-argo-rollouts
# or
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

## Usage

### Deploy
```bash
kubectl apply -f k8s/argo-rollouts/analysis-template.yaml
kubectl apply -f k8s/argo-rollouts/checkout-rollout.yaml
```

### Monitor Rollout Progress
```bash
kubectl argo rollouts get rollout checkout -n retail-store --watch
```

### Manual Promotion (skip analysis)
```bash
kubectl argo rollouts promote checkout -n retail-store
```

### Manual Rollback
```bash
kubectl argo rollouts abort checkout -n retail-store
```

### View Analysis Results
```bash
kubectl argo rollouts get rollout checkout -n retail-store
kubectl get analysisrun -n retail-store
```

## Integration with ArgoCD

The ArgoCD `retail-store` project has been updated to allow Argo Rollout CRDs:
- `Rollout`
- `AnalysisTemplate`  
- `AnalysisRun`

ArgoCD will automatically detect the Rollout resources and manage their lifecycle. The Argo Rollouts controller handles the canary progression independently.

## Production Tuning

For production deployments, consider:
- **Increase pause durations** to 5-10 minutes per step for more observation time
- **Lower the sampling rate** to `parentbased_traceidratio` with a ratio of 0.1 (10%)
- **Add custom metrics** specific to your business KPIs (e.g., order conversion rate)
- **Enable notifications** via Argo Rollouts notification controller for Slack/PagerDuty alerts
- **Use traffic management** with Istio or Traefik for header-based canary routing
