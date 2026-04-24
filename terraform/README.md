# Production Grade & Cost-Optimized EKS Infrastructure

This Terraform configuration deploys a production-grade Amazon EKS cluster optimized for cost-efficiency and cloud-agnostic operations.

## Architecture Improvements

As a Senior DevOps & Cloud Engineer, I have audited and refactored the infrastructure to align with production best practices, ensuring high resilience while aggressively cutting unnecessary AWS costs by relying on robust open-source alternatives.

### 1. Cost-Optimized Compute (Spot + On-Demand Strategy)
- **Previous State**: Single compute configuration (likely on-demand) via EKS Auto Mode.
- **Improved State**: Implemented a dual-pool managed node group architecture:
  - **Core Node Group**: A small On-Demand instance group to host critical cluster addons (CoreDNS, Ingress Controllers, Monitoring). This guarantees cluster stability.
  - **Spot Node Group**: A flexible pool of multiple instance types (t3/t3a medium and large) configured with `capacity_type = "SPOT"`. This runs application workloads at a fraction of the cost (up to 70-90% discount compared to On-Demand).

### 2. Open-Source Monitoring vs CloudWatch
- **Previous State**: Monitoring was either disabled or relied on expensive AWS CloudWatch Container Insights.
- **Improved State**: Enabled `kube-prometheus-stack` by default. This deploys open-source Prometheus and Grafana.
- **Why**: CloudWatch metrics and logs can easily become the most expensive part of a Kubernetes cluster. The open-source stack provides deeper, Kubernetes-native metrics without the vendor lock-in and per-metric/per-GB pricing of AWS.

### 3. GitOps Continuous Delivery (ArgoCD)
- **Previous State**: `argocd.tf` was an empty file, potentially leaving deployments to manual kubectl commands or expensive AWS CodePipeline setups.
- **Improved State**: Fully implemented a High-Availability (HA) ArgoCD installation via the Helm provider directly in Terraform.
- **Why**: ArgoCD is the industry standard for Kubernetes GitOps. It acts as an open-source CD pipeline, eliminating the need to pay for managed deployment services, while ensuring deployment state is version-controlled and self-healing.

### 4. Security & Audit Compliance
- **Previous State**: Cluster logging was completely disabled.
- **Improved State**: Enabled `audit` logs for the EKS control plane.
- **Why**: Production clusters must have an audit trail for security compliance (SOC2, etc.). However, I deliberately left out expensive logs like `api`, `authenticator`, and `controllerManager` to prevent unnecessary CloudWatch log ingestion costs.

### 5. Efficient Networking
- **State**: Maintained the Single NAT Gateway configuration.
- **Why**: While Multi-NAT (one per AZ) is standard for extreme high availability, NAT Gateways are extremely expensive (~$32/month base + per GB processing per AZ). A Single NAT Gateway is a deliberate, highly effective cost-saving measure for teams that don't require 100% strict multi-AZ outbound redundancy.

### 6. Developer Experience
- **Outputs**: Added a comprehensive `outputs.tf` file.
- **Why**: Instantly gives engineers the exact commands they need to authenticate `kubectl` and retrieve the initial ArgoCD admin password, saving them time and reducing onboarding friction.

## Usage

```bash
# Initialize terraform and download providers
terraform init

# Validate the changes
terraform validate

# Plan and apply the infrastructure
terraform plan
terraform apply
```

To access the cluster:
```bash
$(terraform output -raw configure_kubectl)
```

To get the ArgoCD password:
```bash
eval $(terraform output -raw argocd_initial_password_command)
```
