# 🚀 Infrastructure Version Upgrade Changelog

## Overview
Complete version upgrade of all Terraform modules, Helm charts, and Kubernetes version to the latest stable releases as of **May 2026**.

> [!IMPORTANT]
> This is a **major upgrade** across all components. Read through all breaking changes carefully before applying. A `terraform plan` should be run first to preview all changes.

---

## Version Matrix

| Component | Previous Version | New Version | Type | Official Source |
|:---|:---|:---|:---|:---|
| **Kubernetes (EKS)** | `1.31` | `1.35` | Platform | [EKS Versions](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) |
| **Terraform** | `>= 1.0` | `>= 1.5.7` | Provider | [Terraform Downloads](https://developer.hashicorp.com/terraform/install) |
| **AWS Provider** | `>= 5.0` | `>= 6.0` | Provider | [hashicorp/aws](https://registry.terraform.io/providers/hashicorp/aws/latest) |
| **Helm Provider** | `>= 2.0` | `>= 2.17` | Provider | [hashicorp/helm](https://registry.terraform.io/providers/hashicorp/helm/latest) |
| **Kubernetes Provider** | `>= 2.0` | `>= 2.35` | Provider | [hashicorp/kubernetes](https://registry.terraform.io/providers/hashicorp/kubernetes/latest) |
| **VPC Module** | `~> 5.0` | `~> 6.6` | Terraform Module | [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest) |
| **EKS Module** | `~> 20.31` | `~> 21.20` | Terraform Module | [terraform-aws-modules/eks](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest) |
| **IAM Module** | `~> 5.0` | `~> 6.6` | Terraform Module | [terraform-aws-modules/iam](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest) |
| **EKS Blueprints Addons** | `~> 1.0` | `~> 1.23` | Terraform Module | [aws-ia/eks-blueprints-addons](https://github.com/aws-ia/terraform-aws-eks-blueprints-addons/releases) |
| **Karpenter** | `1.4.0` | `1.12.0` | Helm Chart (OCI) | [karpenter.sh](https://karpenter.sh/) |
| **Traefik** | `28.0.0` | `40.0.0` | Helm Chart | [Traefik Helm Chart](https://github.com/traefik/traefik-helm-chart/releases) |
| **KEDA** | `2.14.0` | `2.19.0` | Helm Chart | [KEDA Releases](https://github.com/kedacore/charts/releases) |
| **ArgoCD** | `5.51.6` | `9.5.13` | Helm Chart | [argo-helm Releases](https://github.com/argoproj/argo-helm/releases) |
| **AMI Type** | `AL2_x86_64` | `AL2023_x86_64_STANDARD` | EKS Node AMI | [AL2023 Docs](https://docs.aws.amazon.com/linux/al2023/ug/) |

---

## Detailed Changes Per File

### `versions.tf`
```diff
- required_version = ">= 1.0"
+ required_version = ">= 1.5.7"

  aws     >= 5.0  →  >= 6.0
  helm    >= 2.0  →  >= 2.17
  kubernetes >= 2.0 → >= 2.35
```

**Why:** EKS module v21.x requires Terraform >= 1.5.7 and AWS provider >= 6.0. The helm/kubernetes providers need updates to support K8s 1.35 API features.

---

### `variables.tf`
```diff
- kubernetes_version default = "1.31"
+ kubernetes_version default = "1.35"

- argocd_chart_version default = "5.51.6"
+ argocd_chart_version default = "9.5.13"
```

---

### `main.tf`

| Change | Details |
|:---|:---|
| VPC module | `~> 5.0` → `~> 6.6` |
| EKS module | `~> 20.31` → `~> 21.20` |
| AMI type | `AL2_x86_64` → `AL2023_x86_64_STANDARD` |

> [!WARNING]
> **EKS Module v21 Breaking Changes:**
> - The `aws-auth` ConfigMap management has been replaced by **EKS Access Entries** (already configured in this codebase via `enable_cluster_creator_admin_permissions`).
> - Default AMI type changed to AL2023. This is intentional — **Kubernetes 1.35 deprecates cgroup v1**, and AL2023 uses cgroup v2 by default.
> - Some variable names changed internally in the module. Review `UPGRADE-21.0.md` from the module repo.

> [!WARNING]
> **VPC Module v6 Breaking Changes:**
> - VPC Flow Logs within the root module are deprecated. Use the standalone `vpc-flow-log` submodule in the future.

---

### `addons.tf`

| Chart | Old Version | New Version | Notes |
|:---|:---|:---|:---|
| EKS Blueprints Addons | `~> 1.0` | `~> 1.23` | Adds ListInstanceProfiles permission for Karpenter, load-balancer-controller v2.12+ support |
| Traefik | `28.0.0` | `40.0.0` | Traefik Proxy v3.7.0. **CRDs are now bundled with the chart**. `traefik-crds` standalone chart is deprecated. |
| KEDA | `2.14.0` | `2.19.0` | New Kubernetes Resource Scaler, improved AWS CloudWatch/DynamoDB/MongoDB scalers, file-based auth support |

> [!NOTE]
> **Traefik v40.0.0:** Gateway API CRDs will **no longer be shipped** in future major versions. If you use the Kubernetes Gateway API provider, start managing those CRDs independently.

---

### `karpenter.tf`

| Change | Details |
|:---|:---|
| IAM module | `~> 5.0` → `~> 6.6` |
| Karpenter chart | `1.4.0` → `1.12.0` |

> [!NOTE]
> Karpenter 1.12.0 is compatible with Kubernetes 1.35. Review the [Karpenter Upgrade Guide](https://karpenter.sh/docs/upgrade/) for any breaking changes between v1.4 and v1.12.

---

### `karpenter-nodeclass.yaml`

```diff
- amiFamily: AL2
- amiSelectorTerms:
-   - alias: al2@latest
+ amiFamily: AL2023
+ amiSelectorTerms:
+   - alias: al2023@latest
```

**Why:** Kubernetes 1.35 deprecates cgroup v1. AL2023 uses cgroup v2 by default, making it the required AMI for K8s 1.35+.

---

### `argocd.tf`
The chart version is sourced from `var.argocd_chart_version`, which was updated from `5.51.6` → `9.5.13` in `variables.tf`.

> [!CAUTION]
> **ArgoCD Chart 9.x** packages ArgoCD v3.x, which has significant changes:
> - New RBAC model
> - ApplicationSet v2 API
> - Updated Redis and Dex dependencies
> - Review the [ArgoCD Upgrade Guide](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/) before applying.

---

## Pre-Upgrade Checklist

- [ ] Ensure Terraform CLI is >= 1.5.7: `terraform version`
- [ ] Ensure AWS provider is available >= 6.0
- [ ] Backup current Terraform state: `terraform state pull > backup.tfstate`
- [ ] Run `terraform init -upgrade` to update module/provider caches
- [ ] Run `terraform plan` and review ALL changes before applying
- [ ] Verify EKS supports K8s 1.35 in your region: `aws eks describe-cluster-versions`
- [ ] Test in a **dev/staging** environment before production

## Upgrade Procedure

```bash
# 1. Update provider lock file
terraform init -upgrade

# 2. Review all planned changes
terraform plan -out=upgrade.tfplan

# 3. Apply (after thorough review)
terraform apply upgrade.tfplan
```

> [!CAUTION]
> **EKS cluster upgrades are sequential** — you cannot skip minor versions. If your current cluster is on 1.31, EKS will upgrade through 1.32 → 1.33 → 1.34 → 1.35. This process can take **30-60 minutes per minor version**.

---

## Post-Upgrade Verification

```bash
# Verify cluster version
kubectl version --short

# Verify all nodes are using AL2023
kubectl get nodes -o wide

# Verify Karpenter is running
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter

# Verify Traefik is healthy
kubectl -n traefik-system get pods

# Verify KEDA operator
kubectl -n keda get pods

# Verify ArgoCD
kubectl -n argocd get pods

# Check for any CrashLoopBackOff or pending pods
kubectl get pods --all-namespaces --field-selector status.phase!=Running
```

---

*Generated on: 2026-05-10 | Author: Automated Upgrade Tool*
