# ArgoCD + Kustomize Multi-Cluster EKS Demo

A working demonstration of GitOps using ArgoCD and Kustomize to manage a Pega Platform deployment across 6 EKS clusters from a single management cluster. Includes multi-tier Pega nodes (Web, Batch, Stream), Strimzi Kafka, Karpenter autoscaling, and HPA -- all driven from a single Git repository.

## Architecture

```
                         GitHub Repository
                               │
                     ┌─────────┴─────────┐
                     │  Management Cluster │
                     │    (ArgoCD Hub)     │
                     └─────────┬─────────┘
                               │
         ┌───────┬────────┬────┴────┬────────┬────────┐
         ▼       ▼        ▼        ▼        ▼        ▼
      ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
      │eks-  │ │eks-  │ │eks-  │ │eks-  │ │eks-  │ │eks-  │
      │ops   │ │sbx   │ │test  │ │impl  │ │trng  │ │prod  │
      │(VPC) │ │(VPC) │ │(VPC) │ │(VPC) │ │(VPC) │ │(VPC) │
      └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘
       auto     auto     auto     auto     auto    manual
       sync     sync     sync     sync     sync     sync
```

**Local demo:** All 6 "clusters" are simulated on a single Kind cluster using per-env namespaces (`pega-ops`, `pega-sbx`, etc.) and ArgoCD cluster secrets that all resolve to `https://kubernetes.default.svc`.

**Production:** Each `destination.name` (e.g., `eks-prod`) resolves to a separate EKS cluster in its own VPC, and the namespace is simply `pega`.

## Environments

| Environment | Web | Batch | Stream | HPA | Kafka | Karpenter | ALB | Sync |
|-------------|-----|-------|--------|-----|-------|-----------|-----|------|
| **OPS** | 1 | 1 | 1 | 1-2 | 1 broker | spot+od | internal | Auto |
| **SBX** | 1 | 1 | 1 | 1-2 | 1 broker | spot | internal | Auto |
| **TEST** | 2 | 1 | 1 | 2-4 | 1 broker | spot+od | internal | Auto |
| **IMPL** | 2 | 2 | 2 | 2-6 | 3 brokers RF=2 | on-demand | internal | Auto |
| **TRNG** | 2 | 1 | 1 | 2-4 | 1 broker | spot+od | internal | Auto |
| **PROD** | 4 | 2 | 2 | 4-12 | 3 brokers RF=3 persistent | on-demand | **internet-facing** | **Manual** |

## Repository Structure

```
.
├── base/                           # Shared base manifests
│   ├── app/                        # Pega multi-tier: 3 Deployments, Service, ConfigMap, Ingress, HPA
│   │   ├── deployment.yaml         # Web tier (WebUser node type)
│   │   ├── deployment-batch.yaml   # Batch tier (BackgroundProcessing/Search/Batch)
│   │   ├── deployment-stream.yaml  # Stream tier (Kafka consumer, references KAFKA_BOOTSTRAP_SERVERS)
│   │   ├── service.yaml            # ClusterIP service for web tier
│   │   ├── configmap.yaml          # JDBC_URL, CLUSTER_NAME, KAFKA_BOOTSTRAP_SERVERS
│   │   ├── ingress.yaml            # AWS ALB with TLS, health checks
│   │   ├── hpa.yaml                # HorizontalPodAutoscaler for web tier
│   │   └── kustomization.yaml
│   ├── strimzi/                    # Kafka cluster and KafkaTopic definitions
│   └── karpenter/                  # NodePool and EC2NodeClass definitions
├── overlays/                       # Per-environment Kustomize overlays
│   ├── ops/
│   │   ├── kustomization.yaml      # namespace: pega-ops, references 7 patches
│   │   └── patches/
│   │       ├── app-replicas.yaml       # Web/Batch/Stream replica counts + resources
│   │       ├── configmap-env.yaml      # JDBC_URL, CLUSTER_NAME, KAFKA_BOOTSTRAP_SERVERS
│   │       ├── ingress-host.yaml       # ALB cert ARN, hostname
│   │       ├── kafka-sizing.yaml       # Kafka broker count, RF, resources
│   │       ├── karpenter-limits.yaml   # Instance types, capacity type, limits
│   │       ├── ec2nodeclass-cluster.yaml  # VPC subnet/SG discovery tags
│   │       └── hpa-scaling.yaml        # HPA min/max replicas
│   ├── sbx/  ... (same structure)
│   ├── test/ ... (same structure)
│   ├── impl/ ... (same structure)
│   ├── trng/ ... (same structure)
│   └── prod/                       # Adds kafka-storage.yaml for persistent volumes
├── argocd/                         # ArgoCD Application manifests
│   ├── app-of-apps.yaml            # Parent Application (targets in-cluster)
│   ├── app-ops.yaml                # destination.name: eks-ops
│   ├── app-sbx.yaml                # destination.name: eks-sbx
│   ├── app-test.yaml               # destination.name: eks-test
│   ├── app-impl.yaml               # destination.name: eks-impl
│   ├── app-trng.yaml               # destination.name: eks-trng
│   ├── app-prod.yaml               # destination.name: eks-prod (manual sync)
│   ├── project.yaml                # AppProject: restricts repos, clusters, namespaces
│   └── clusters/
│       ├── cluster-secrets.yaml    # 6 cluster secrets (local: all point to Kind)
│       └── README.md               # How cluster registration works in production
├── kind-config.yaml
├── setup.sh                        # Automated setup (8 steps)
└── RUNBOOK.md                      # Detailed guide with demo scenarios
```

## Quick Start

### Prerequisites

```bash
brew install kubectl kind kustomize
```

Docker Desktop must be installed and running.

### Automated Setup

```bash
git clone https://github.com/suryayelagam/argocd-kustomize-explore.git
cd argocd-kustomize-explore
./setup.sh
```

The script will:
1. Create a Kind cluster (`argocd-demo`)
2. Install ArgoCD and expose the UI at `https://localhost:8443`
3. Install Strimzi and Karpenter CRDs
4. Create 6 namespaces (`pega-ops` through `pega-prod`)
5. Register 6 cluster secrets (all pointing to the local Kind cluster)
6. Create the `pega-platform` AppProject

### Deploy Applications

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

This single command bootstraps all 6 environment Applications via the app-of-apps pattern. Open `https://localhost:8443` to see all 6 apps syncing.

## How It Works

### Multi-Cluster via Named Destinations

Each ArgoCD Application uses `destination.name` instead of `destination.server`:

```yaml
# argocd/app-prod.yaml
destination:
  name: eks-prod           # Resolves to a cluster secret
  namespace: pega-prod     # Local demo namespace
```

ArgoCD looks up the cluster secret labeled `argocd.argoproj.io/secret-type: cluster` with a matching name. Locally, all 6 secrets point to `https://kubernetes.default.svc`. In production, each would contain the actual EKS API server URL and IAM credentials.

### Multi-Tier Pega Architecture

Each environment deploys 3 Deployment tiers:
- **pega-web** -- WebUser nodes, fronted by ALB Ingress, scaled by HPA
- **pega-batch** -- BackgroundProcessing/Search/Batch nodes
- **pega-stream** -- Stream nodes, consuming from Kafka

### Adapting for Real EKS

1. Replace cluster secrets with `argocd cluster add`:
   ```bash
   argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-prod --name eks-prod
   ```
2. Change overlay namespaces from `pega-<env>` to `pega`
3. Update ACM certificate ARNs in ingress patches
4. Point JDBC_URL to actual RDS endpoints

## Cleanup

```bash
kind delete cluster --name argocd-demo
```

## Documentation

See [RUNBOOK.md](RUNBOOK.md) for:
- Management cluster architecture concepts
- Detailed setup walkthrough
- 5 ready-to-run demo scenarios
- "Adapting for Real EKS" guide
- Quick reference command table
