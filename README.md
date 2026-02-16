# ArgoCD + Kustomize Multi-Environment Demo

A working demonstration of GitOps using ArgoCD and Kustomize to manage 6 Kubernetes environments from a single Git repository. Includes Strimzi (Kafka) and Karpenter resource definitions to reflect a real-world platform setup.

## Architecture

```
                        GitHub Repository
                              │
                    ┌─────────┴─────────┐
                    │    ArgoCD Server   │
                    │  (watches for git  │
                    │   changes)         │
                    └─────────┬─────────┘
                              │
          ┌───────┬───────┬───┴───┬───────┬───────┐
          ▼       ▼       ▼       ▼       ▼       ▼
        ┌─────┐ ┌─────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
        │ OPS │ │ SBX │ │ TEST │ │ IMPL │ │ TRNG │ │ PROD │
        └─────┘ └─────┘ └──────┘ └──────┘ └──────┘ └──────┘
         auto    auto    auto     auto     auto    manual
         sync    sync    sync     sync     sync     sync
```

## Environments

| Environment | Replicas | Kafka Brokers | Karpenter Instances | ArgoCD Sync |
|-------------|----------|---------------|---------------------|-------------|
| **OPS** | 1 | 1 | spot + on-demand, m5.large | Automated |
| **SBX** | 1 | 1 | spot only, m5.large | Automated |
| **TEST** | 2 | 1 | spot + on-demand, up to m5.2xlarge | Automated |
| **IMPL** | 2 | 3 (RF=2) | on-demand, up to m5.2xlarge | Automated |
| **TRNG** | 2 | 1 | spot + on-demand, m5.xlarge | Automated |
| **PROD** | 4 | 3 (RF=3, persistent) | on-demand, up to m5.4xlarge | **Manual** |

## Repository Structure

```
.
├── base/                        # Shared base manifests
│   ├── app/                     # Pega web tier: Deployment, Service, ConfigMap, Ingress
│   ├── strimzi/                 # Kafka cluster and KafkaTopic definitions
│   └── karpenter/               # NodePool and EC2NodeClass definitions
├── overlays/                    # Per-environment Kustomize overlays
│   ├── ops/
│   │   ├── kustomization.yaml   # References base + applies patches
│   │   └── patches/             # Environment-specific overrides
│   ├── sbx/
│   ├── test/
│   ├── impl/
│   ├── trng/
│   └── prod/
├── argocd/                      # ArgoCD Application manifests
│   ├── app-of-apps.yaml         # Parent Application that manages all env apps
│   ├── app-ops.yaml
│   ├── app-sbx.yaml
│   ├── app-test.yaml
│   ├── app-impl.yaml
│   ├── app-trng.yaml
│   └── app-prod.yaml
├── kind-config.yaml             # Kind cluster configuration with port mappings
├── setup.sh                     # Automated setup script
└── RUNBOOK.md                   # Detailed step-by-step guide with demo scenarios
```

## Quick Start

### Prerequisites

```bash
brew install kubectl kind helm kustomize
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
2. Install ArgoCD and expose the UI
3. Create all environment namespaces
4. Print the ArgoCD admin credentials

### Deploy Applications

Install the required CRDs, then deploy the ArgoCD Applications:

```bash
# Install Strimzi and Karpenter CRDs (see RUNBOOK.md for full commands)
# Then deploy all applications:
kubectl apply -f argocd/app-ops.yaml \
              -f argocd/app-sbx.yaml \
              -f argocd/app-test.yaml \
              -f argocd/app-impl.yaml \
              -f argocd/app-trng.yaml \
              -f argocd/app-prod.yaml
```

Open `https://localhost:8443` to access the ArgoCD dashboard.

## How It Works

### Kustomize: Base + Overlays

The `base/` directory contains shared Kubernetes manifests with default values. Each environment in `overlays/` applies targeted patches to customize replicas, resource limits, Kafka replication factors, Karpenter instance types, and more.

```bash
# Preview the final manifests for any environment
kustomize build overlays/prod

# Compare what differs between two environments
diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)
```

### ArgoCD: Continuous Reconciliation

Each ArgoCD Application watches a specific `overlays/<env>` path in this repository. When a commit is pushed:

- **OPS, SBX, TEST, IMPL, TRNG:** ArgoCD automatically syncs the changes (with pruning and self-healing enabled)
- **PROD:** ArgoCD detects the change and marks the app as OutOfSync, but waits for a manual sync approval via the UI

### Self-Healing

With `selfHeal: true`, ArgoCD continuously compares the live cluster state against Git. If a resource is manually modified or deleted, ArgoCD restores it to match the declared state within seconds.

## Cleanup

```bash
kind delete cluster --name argocd-demo
```

## Documentation

See [RUNBOOK.md](RUNBOOK.md) for:
- Detailed setup instructions with explanations
- 5 ready-to-run demo scenarios
- Talking points for presenting to stakeholders
- Quick reference command table
