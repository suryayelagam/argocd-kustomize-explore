# ArgoCD + Kustomize Multi-Cluster EKS Demo

A working demonstration of GitOps using ArgoCD and Kustomize to manage a Pega Platform deployment across 6 EKS clusters. Each cluster runs its own ArgoCD instance that manages only its own resources, all driven from a single Git repository.

## Architecture

```
                         GitHub Repository
                               │
        ┌───────┬────────┬─────┴─────┬────────┬────────┐
        ▼       ▼        ▼           ▼        ▼        ▼
     ┌──────┐ ┌──────┐ ┌──────┐  ┌──────┐ ┌──────┐ ┌──────┐
     │eks-  │ │eks-  │ │eks-  │  │eks-  │ │eks-  │ │eks-  │
     │ops   │ │sbx   │ │test  │  │impl  │ │trng  │ │prod  │
     │(VPC) │ │(VPC) │ │(VPC) │  │(VPC) │ │(VPC) │ │(VPC) │
     │      │ │      │ │      │  │      │ │      │ │      │
     │ArgoCD│ │ArgoCD│ │ArgoCD│  │ArgoCD│ │ArgoCD│ │ArgoCD│
     └──────┘ └──────┘ └──────┘  └──────┘ └──────┘ └──────┘
      auto     auto     auto      auto     auto    manual
      sync     sync     sync      sync     sync     sync
```

Each EKS cluster has its own ArgoCD installation in the `argocd` namespace. ArgoCD deploys to the local cluster only (`https://kubernetes.default.svc`) -- there is no cross-cluster management or central hub.

**Local demo:** All 6 environments are simulated on a single Kind cluster using per-env namespaces (`pega-ops`, `pega-sbx`, etc.) with one shared ArgoCD instance and an app-of-apps pattern to deploy all 6 at once.

**Production:** Each EKS cluster installs ArgoCD independently and applies only its own Application manifest (e.g., `eks-prod` applies `app-prod.yaml`). The namespace is simply `pega`.

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
│   ├── app/                        # Pega multi-tier application resources
│   │   ├── deployment.yaml         # Web tier (WebUser node type)
│   │   ├── deployment-batch.yaml   # Batch tier (BackgroundProcessing/Search/Batch/BIX)
│   │   ├── deployment-stream.yaml  # Stream tier (Kafka consumer)
│   │   ├── service.yaml            # ClusterIP service for web tier (ports 80, 443)
│   │   ├── configmap-env.yaml      # Shared env config: JDBC, schemas, streaming, Hazelcast
│   │   ├── configmap-web.yaml      # Web tier: prconfig.xml, context.xml.tmpl, prlog4j2.xml
│   │   ├── configmap-batch.yaml    # Batch tier: prconfig.xml, context.xml.tmpl, prlog4j2.xml
│   │   ├── configmap-stream.yaml   # Stream tier: prconfig.xml, context.xml.tmpl, prlog4j2.xml
│   │   ├── secret-db.yaml          # DB credentials (DB_USERNAME, DB_PASSWORD)
│   │   ├── secret-stream.yaml      # Stream security (JAAS, truststore, keystore)
│   │   ├── ingress.yaml            # AWS ALB with TLS, health checks
│   │   ├── hpa.yaml                # HorizontalPodAutoscaler for web tier
│   │   ├── pdb-web.yaml            # PodDisruptionBudget for web tier
│   │   ├── pdb-batch.yaml          # PodDisruptionBudget for batch tier
│   │   ├── pdb-stream.yaml         # PodDisruptionBudget for stream tier
│   │   └── kustomization.yaml
│   ├── strimzi/                    # Kafka cluster and KafkaTopic definitions
│   └── karpenter/                  # NodePool and EC2NodeClass definitions
├── overlays/                       # Per-environment Kustomize overlays
│   ├── ops/
│   │   ├── kustomization.yaml      # namespace: pega-ops, references 7 patches
│   │   └── patches/
│   │       ├── app-replicas.yaml       # Web/Batch/Stream replica counts + resources
│   │       ├── configmap-env.yaml      # JDBC_URL, CLUSTER_NAME, ENVIRONMENT
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
│   ├── app-of-apps.yaml            # Local demo only: deploys all 6 apps at once
│   ├── app-ops.yaml                # ArgoCD Application for ops environment
│   ├── app-sbx.yaml                # ArgoCD Application for sbx environment
│   ├── app-test.yaml               # ArgoCD Application for test environment
│   ├── app-impl.yaml               # ArgoCD Application for impl environment
│   ├── app-trng.yaml               # ArgoCD Application for trng environment
│   ├── app-prod.yaml               # ArgoCD Application for prod (manual sync)
│   ├── project.yaml                # AppProject: restricts repos, namespaces, resource types
│   └── clusters/
│       ├── cluster-secrets.yaml    # Local demo only: 6 cluster secrets for Kind
│       └── README.md               # How cluster registration works in production
├── kind-config.yaml
├── setup.sh                        # Automated local demo setup (8 steps)
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

### Per-Cluster ArgoCD (Production)

In production, each EKS cluster runs its own ArgoCD instance. There is no central management cluster. Each cluster's ArgoCD:

1. Watches the same Git repository
2. Deploys only its own Application (e.g., `eks-prod` runs `app-prod.yaml`)
3. Targets `https://kubernetes.default.svc` (in-cluster only)
4. Runs in the `argocd` namespace alongside Pega workloads

To set up a new cluster:
```bash
# Install ArgoCD on the cluster
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Apply the AppProject and the cluster's Application
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/app-prod.yaml   # or app-ops.yaml, app-test.yaml, etc.
```

### Local Demo (Kind)

The local demo uses a single Kind cluster with one ArgoCD instance to simulate all 6 environments. The app-of-apps pattern (`app-of-apps.yaml`) and cluster secrets (`clusters/cluster-secrets.yaml`) are **local demo conveniences only** -- they are not used in production.

### Multi-Tier Pega Architecture

Each environment deploys 3 Deployment tiers:
- **pega-web** -- WebUser nodes, fronted by ALB Ingress, scaled by HPA
- **pega-batch** -- BackgroundProcessing/Search/Batch/BIX nodes
- **pega-stream** -- Stream nodes, consuming from Kafka

### Adapting for Real EKS

1. Install ArgoCD on each EKS cluster independently
2. Apply `project.yaml` and the cluster's specific `app-<env>.yaml`
3. Change overlay namespaces from `pega-<env>` to `pega`
4. Update ACM certificate ARNs in ingress patches
5. Point JDBC_URL to actual RDS endpoints
6. Replace DB secret placeholder credentials with real values (or use External Secrets)

## Cleanup

```bash
kind delete cluster --name argocd-demo
```

## Documentation

See [RUNBOOK.md](RUNBOOK.md) for:
- Per-cluster ArgoCD setup guide
- Detailed setup walkthrough
- 5 ready-to-run demo scenarios
- "Adapting for Real EKS" guide
- Quick reference command table
