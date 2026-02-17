# ArgoCD Multi-Cluster EKS Demo Runbook

## Overview

This runbook walks through setting up a local ArgoCD multi-cluster demo that manages Pega Platform deployments across 6 EKS clusters from a single management cluster. Each cluster runs a multi-tier Pega deployment (Web, Batch, Stream) with Kafka, Karpenter autoscaling, and HPA.

**What you'll see by the end:** ArgoCD managing 6 named clusters from a central hub, with a single Git push automatically rolling out multi-tier Pega changes across 5 environments while PROD is held for manual approval.

---

## Architecture

```
                      ┌──────────────────────────────┐
                      │    Management Cluster (Kind)  │
                      │                              │
                      │   ┌────────────────────┐     │
                      │   │   ArgoCD Server     │     │
                      │   │   (watches GitHub)  │     │
                      │   └────────┬───────────┘     │
                      └────────────┼─────────────────┘
                                   │
            ┌──────────┬──────────┬┴──────────┬──────────┬──────────┐
            ▼          ▼          ▼           ▼          ▼          ▼
       ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
       │ eks-ops │ │ eks-sbx │ │eks-test │ │eks-impl │ │eks-trng │ │eks-prod │
       │ (VPC-1) │ │ (VPC-2) │ │ (VPC-3) │ │ (VPC-4) │ │ (VPC-5) │ │ (VPC-6) │
       │         │ │         │ │         │ │         │ │         │ │         │
       │ pega-web│ │ pega-web│ │ pega-web│ │ pega-web│ │ pega-web│ │ pega-web│
       │ pega-   │ │ pega-   │ │ pega-   │ │ pega-   │ │ pega-   │ │ pega-   │
       │  batch  │ │  batch  │ │  batch  │ │  batch  │ │  batch  │ │  batch  │
       │ pega-   │ │ pega-   │ │ pega-   │ │ pega-   │ │ pega-   │ │ pega-   │
       │  stream │ │  stream │ │  stream │ │  stream │ │  stream │ │  stream │
       │ kafka   │ │ kafka   │ │ kafka   │ │ kafka   │ │ kafka   │ │ kafka   │
       └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘
         auto        auto        auto        auto        auto       MANUAL
```

**Local demo:** All 6 clusters are simulated as namespaces (`pega-ops`, `pega-sbx`, etc.) on a single Kind cluster. ArgoCD cluster secrets all point to `https://kubernetes.default.svc`.

---

## Key Concepts

| Concept | Description |
|---------|-------------|
| **Management Cluster** | The central cluster where ArgoCD runs. It doesn't host application workloads -- it manages other clusters. |
| **Cluster Secrets** | Kubernetes Secrets labeled `argocd.argoproj.io/secret-type: cluster` that register target clusters with ArgoCD by name. |
| **AppProject** | ArgoCD resource that restricts which repos, clusters, and namespaces an Application can target. Security boundary. |
| **destination.name** | ArgoCD Application field that references a cluster by name (from cluster secrets) instead of by API server URL. |
| **Multi-Tier Pega** | Web (user-facing), Batch (background processing), Stream (Kafka consumers) -- each is a separate Deployment. |
| **Kustomize** | Base + overlay pattern: shared manifests with per-environment patches. No duplication. |
| **Strimzi** | Kubernetes operator for Apache Kafka. Uses `Kafka` and `KafkaTopic` Custom Resources. |
| **Karpenter** | AWS node autoscaler. Uses `NodePool` and `EC2NodeClass` to provision right-sized EC2 instances. |
| **HPA** | Horizontal Pod Autoscaler. Scales pega-web pods based on CPU/memory utilization. |

---

## Prerequisites

```bash
brew install kubectl kind kustomize
```

You also need:
- **Docker Desktop** installed and running
- **Git** configured with access to your GitHub account

---

## Setup

### Automated (Recommended)

```bash
./setup.sh
```

This runs all 8 steps below automatically. If you prefer to understand each step, follow the manual walkthrough.

### Manual Walkthrough

#### Step 1: Create the Kind Cluster

```bash
kind create cluster --name argocd-demo --config kind-config.yaml --wait 60s
kubectl cluster-info --context kind-argocd-demo
```

#### Step 2: Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
```

#### Step 3: Expose the ArgoCD UI

```bash
kubectl patch svc argocd-server -n argocd -p '{
  "spec": {
    "type": "NodePort",
    "ports": [{"name": "https", "port": 443, "targetPort": 8080, "nodePort": 30443}]
  }
}'
```

UI available at `https://localhost:8443` (accept the self-signed cert warning).

#### Step 4: Retrieve the Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

| Field | Value |
|-------|-------|
| URL | `https://localhost:8443` |
| Username | `admin` |
| Password | _(output from above)_ |

#### Step 5: Install CRDs

The manifests reference Strimzi Kafka and Karpenter resources. The CRDs must be registered before ArgoCD can sync them.

```bash
# Strimzi CRDs
kubectl apply -f https://strimzi.io/install/latest?namespace=default

# Karpenter CRDs (minimal schema for demo)
# See setup.sh for the full inline CRD definitions
```

#### Step 6: Create Environment Namespaces

```bash
for ns in pega-ops pega-sbx pega-test pega-impl pega-trng pega-prod; do
  kubectl create namespace $ns
done
```

#### Step 7: Register Cluster Secrets

```bash
kubectl apply -f argocd/clusters/cluster-secrets.yaml
```

This creates 6 Kubernetes Secrets in the `argocd` namespace, each labeled `argocd.argoproj.io/secret-type: cluster`. ArgoCD uses these to resolve `destination.name` in Application manifests.

For production, use `argocd cluster add` instead (see `argocd/clusters/README.md`).

#### Step 8: Create the AppProject

```bash
kubectl apply -f argocd/project.yaml
```

The `pega-platform` AppProject restricts Applications to:
- Source: only this Git repository
- Destinations: only the 6 named EKS clusters
- Namespaces: only `pega-*` namespaces

#### Deploy

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

---

## Demo Scenarios

### Demo 1: Multi-Cluster GitOps -- Push and Watch

**Goal:** Show a single Git push propagating across 6 clusters.

1. Open the ArgoCD UI -- all 6 apps are visible as tiles
2. Modify `base/app/deployment.yaml` (e.g., change the image tag):
   ```bash
   # Change: image: nginx:1.25-alpine → image: nginx:1.27-alpine
   git add base/app/deployment.yaml
   git commit -m "Upgrade nginx to 1.27"
   git push origin master
   ```
3. Watch ArgoCD detect the change and sync all 5 auto-sync environments
4. PROD shows **OutOfSync** -- requires manual approval

**Key takeaway:** One commit changes the base. All 6 clusters update. Three Deployments (web, batch, stream) each get the new image. PROD remains gated.

---

### Demo 2: Self-Healing

**Goal:** Show ArgoCD restoring manually deleted resources.

```bash
# Delete a deployment from the test cluster
kubectl delete deployment pega-web -n pega-test
# ArgoCD detects the drift and recreates it within seconds

# Delete a batch pod
kubectl delete pod -n pega-ops -l app=pega-batch --wait=false
# ReplicaSet recreates the pod; ArgoCD confirms the state is healthy
```

**Key takeaway:** The desired state is in Git, not the cluster. Drift is automatically corrected.

---

### Demo 3: Environment Comparison

**Goal:** Show the power of Kustomize overlays for environment differentiation.

```bash
# Compare OPS (minimal) vs PROD (full HA)
diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)

# Highlights:
# - OPS: 1 replica per tier, 100m CPU, spot instances, 1 Kafka broker
# - PROD: 4 web / 2 batch / 2 stream replicas, 1 CPU, on-demand instances,
#          3 Kafka brokers RF=3, persistent storage, zone spreading, HPA 4-12
```

In the ArgoCD UI, click any app to see the full resource tree: 3 Deployments, HPA, Service, ConfigMap, Ingress, Kafka, KafkaTopic, NodePool, EC2NodeClass.

---

### Demo 4: Production Gating

**Goal:** Show PROD is protected from automatic deployments.

1. After a Git push, `pega-prod` shows **OutOfSync** (orange)
2. Click `pega-prod` > **Sync** to review the diff
3. ArgoCD shows exactly what will change across all 11 resources
4. Click **Synchronize** to approve

**Key takeaway:** PROD requires explicit human approval enforced at the system level, not as a skippable process.

---

### Demo 5: Multi-Tier Architecture

**Goal:** Show how one overlay controls all 3 Pega tiers.

```bash
# The overlays patch all 3 deployments in a single file
cat overlays/prod/patches/app-replicas.yaml

# Shows: pega-web (4 replicas), pega-batch (2), pega-stream (2)
# All with topology spread constraints across AZs

# View the HPA scaling config
cat overlays/prod/patches/hpa-scaling.yaml
# Shows: minReplicas: 4, maxReplicas: 12 for pega-web
```

---

## Adapting for Real EKS

### 1. Cluster Registration

Replace the demo cluster secrets with proper `argocd cluster add` commands:

```bash
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-ops --name eks-ops
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-sbx --name eks-sbx
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-test --name eks-test
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-impl --name eks-impl
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-trng --name eks-trng
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-prod --name eks-prod
```

### 2. Namespace Changes

Update each overlay `kustomization.yaml` namespace from `pega-<env>` to `pega` (since each environment has its own cluster, no need for namespace isolation).

### 3. Ingress Configuration

Update each overlay's `ingress-host.yaml`:
- Replace placeholder ACM certificate ARNs with real ones
- Set hostnames to your actual DNS entries
- PROD: confirm `alb.ingress.kubernetes.io/scheme: internet-facing`

### 4. Database Connections

Update each overlay's `configmap-env.yaml`:
- `JDBC_URL`: point to actual RDS endpoints
- `KAFKA_BOOTSTRAP_SERVERS`: point to actual MSK or Strimzi brokers

### 5. Karpenter VPC Tags

Update each overlay's `ec2nodeclass-cluster.yaml`:
- Subnet and security group discovery tags must match your VPC tagging scheme

---

## Quick Reference

| Task | Command |
|------|---------|
| List all ArgoCD apps | `kubectl get applications -n argocd` |
| Check pods in an env | `kubectl get pods -n pega-test` |
| Check all env pods | `for ns in pega-ops pega-sbx pega-test pega-impl pega-trng pega-prod; do echo "=== $ns ===" && kubectl get pods -n $ns; done` |
| Preview manifests | `kustomize build overlays/test` |
| Compare two envs | `diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)` |
| Count resources per env | `kustomize build overlays/ops \| grep "^kind:" \| sort \| uniq -c` |
| List registered clusters | `kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster` |
| Force ArgoCD refresh | Click Refresh in UI, or `kubectl annotate app pega-ops -n argocd argocd.argoproj.io/refresh=hard` |
| View ArgoCD logs | `kubectl logs -n argocd deployment/argocd-server` |
| Retrieve admin password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |
| Tear down demo | `kind delete cluster --name argocd-demo` |

---

## Cleanup

```bash
kind delete cluster --name argocd-demo
```

This deletes the cluster and all associated Docker containers. Nothing persists on the host.

---

## Why ArgoCD? (Discussion Points)

| Traditional Approach | GitOps with ArgoCD |
|---------------------|-------------------|
| Engineers run `kubectl apply` from their laptops | All changes go through Git with PR review and approval |
| No clear audit trail for deployments | Full Git history: who changed what, when, and why |
| Cluster configuration drifts silently | ArgoCD continuously monitors and corrects drift |
| Managing N clusters means N times the manual effort | One management cluster manages all targets centrally |
| Copy-pasting manifests across clusters | One base template + N lightweight overlays via Kustomize |
| Production deployments are manual, error-prone | Production deployments are reviewed diffs with one-click approval |
| Rollback means finding and reapplying old manifests | Rollback is `git revert` -- ArgoCD handles the rest |
| Each cluster is a snowflake | Environment parity is enforced by the tooling |
