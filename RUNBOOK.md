# ArgoCD + Kustomize Demo Runbook

## Overview

This runbook walks through setting up a local ArgoCD + Kustomize demo that manages 6 environments (OPS, SBX, TEST, IMPL, TRNG, PROD) with Strimzi Kafka and Karpenter resources. It is designed to be followed step-by-step, even if you're new to GitOps.

**What you'll see by the end:** A single Git push automatically rolling out changes across 5 environments, with PROD held for manual approval -- all visible in ArgoCD's dashboard.

---

## Key Concepts

| Tool | Purpose |
|------|---------|
| **ArgoCD** | A GitOps continuous delivery tool. It watches a Git repository and continuously reconciles the Kubernetes cluster to match the declared state in Git. If someone manually changes the cluster, ArgoCD detects the drift and corrects it. |
| **Kustomize** | A configuration management tool built into `kubectl`. It lets you define a shared base of Kubernetes manifests, then apply per-environment overrides (called overlays) without duplicating files. |
| **Kind** | "Kubernetes IN Docker" -- a tool that runs a fully functional Kubernetes cluster locally inside Docker containers. Ideal for development and demos. |
| **Strimzi** | A Kubernetes operator for running Apache Kafka clusters. It uses Custom Resources (e.g., `Kafka`, `KafkaTopic`) to define Kafka infrastructure declaratively. |
| **Karpenter** | A Kubernetes node autoscaler (AWS). It provisions and terminates EC2 instances based on workload demand using `NodePool` and `EC2NodeClass` Custom Resources. |

---

## Prerequisites

Install the following tools via Homebrew:

```bash
brew install kubectl kind helm kustomize
```

You also need:
- **Docker Desktop** installed and running
- **Git** configured with access to your GitHub account

---

## Step-by-Step Setup

### Step 1: Start Docker Desktop

Launch Docker Desktop and wait until the status indicator confirms it is running. Kind requires a running Docker daemon to create clusters.

---

### Step 2: Create the Kind Cluster

```bash
kind create cluster --name argocd-demo --config kind-config.yaml --wait 60s
```

This creates a single-node Kubernetes cluster named `argocd-demo`. The `kind-config.yaml` includes port mappings so the ArgoCD UI will be accessible at `https://localhost:8443`.

**Verify:**
```bash
kubectl cluster-info --context kind-argocd-demo
```

You should see the Kubernetes control plane URL in the output.

---

### Step 3: Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

This creates the `argocd` namespace and deploys the full ArgoCD stack (server, repo-server, application controller, redis, dex, and notifications controller).

**Wait for the server to become available:**
```bash
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
```

Typically takes 30-60 seconds.

---

### Step 4: Expose the ArgoCD UI

By default, the ArgoCD server is only accessible from within the cluster. Expose it via NodePort so your browser can reach it:

```bash
kubectl patch svc argocd-server -n argocd -p '{
  "spec": {
    "type": "NodePort",
    "ports": [{"name": "https", "port": 443, "targetPort": 8080, "nodePort": 30443}]
  }
}'
```

The ArgoCD UI is now available at `https://localhost:8443`. Your browser will show a certificate warning for the self-signed cert -- this is expected for a local setup.

---

### Step 5: Retrieve the Admin Password

ArgoCD generates a random admin password at install time and stores it as a Kubernetes Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**Login credentials:**
| Field | Value |
|-------|-------|
| URL | `https://localhost:8443` |
| Username | `admin` |
| Password | _(output from the command above)_ |

---

### Step 6: Install Custom Resource Definitions (CRDs)

Our manifests include Strimzi Kafka and Karpenter resources. Kubernetes needs the CRD definitions registered before it can accept these resource types. We install the CRDs only -- not the full operators -- since this is a demo environment.

```bash
# Strimzi CRDs
kubectl apply -f https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/packaging/install/cluster-operator/040-Crd-kafka.yaml
kubectl apply -f https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/packaging/install/cluster-operator/043-Crd-kafkatopic.yaml

# Karpenter CRDs
kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: nodepools.karpenter.sh
spec:
  group: karpenter.sh
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
  scope: Cluster
  names:
    plural: nodepools
    singular: nodepool
    kind: NodePool
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ec2nodeclasses.karpenter.k8s.aws
spec:
  group: karpenter.k8s.aws
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
  scope: Cluster
  names:
    plural: ec2nodeclasses
    singular: ec2nodeclass
    kind: EC2NodeClass
EOF
```

> **Note:** In a real environment, you would install the full Strimzi operator and Karpenter controller. Here we only register the CRD schemas so ArgoCD can manage the resource definitions without errors.

---

### Step 7: Create the Environment Namespaces

```bash
for ns in ops sbx test impl trng prod; do
  kubectl create namespace $ns
done
```

Each environment is isolated in its own namespace. This prevents resource name collisions and allows for per-namespace access controls and resource quotas.

---

### Step 8: Deploy the ArgoCD Applications

```bash
kubectl apply -f argocd/app-ops.yaml \
              -f argocd/app-sbx.yaml \
              -f argocd/app-test.yaml \
              -f argocd/app-impl.yaml \
              -f argocd/app-trng.yaml \
              -f argocd/app-prod.yaml
```

Each Application manifest tells ArgoCD:
- **Source:** Which Git repository and directory path to watch (e.g., `overlays/ops`)
- **Destination:** Which cluster and namespace to deploy into
- **Sync policy:** Whether to sync automatically or require manual approval

OPS through TRNG are configured with `automated` sync (including `prune` and `selfHeal`). PROD is configured for **manual sync only**.

---

### Step 9: Verify in the ArgoCD UI

Open `https://localhost:8443` in your browser. You should see 6 application tiles:

| Status | Meaning |
|--------|---------|
| **Synced** (green) | Cluster state matches Git -- all resources are deployed and healthy |
| **Progressing** (yellow) | ArgoCD is actively deploying or waiting for resources to become ready |
| **OutOfSync** (orange) | The cluster state does not match Git -- a sync is needed |
| **Degraded** (red) | One or more resources have failed health checks |

Click on any application to see the full resource tree (Deployment, ReplicaSet, Pod, Service, ConfigMap, Ingress, Kafka, KafkaTopic, NodePool, EC2NodeClass).

---

## Project Structure Explained

### Base Layer

```
base/
├── app/          # Pega web application: Deployment, Service, ConfigMap, Ingress
├── strimzi/      # Kafka cluster and CDC topic definitions
└── karpenter/    # NodePool and EC2NodeClass definitions
```

The base contains the canonical resource definitions with sensible defaults. All environments inherit from this.

### Overlay Layer

```
overlays/
├── ops/          # 1 replica, minimal resources, spot + on-demand instances
├── sbx/          # 1 replica, minimal resources, spot instances only
├── test/         # 2 replicas, medium resources, mixed instance types
├── impl/         # 2 replicas, production-like resources, 3-node Kafka (RF=2)
├── trng/         # 2 replicas, medium resources, mixed instances
└── prod/         # 4 replicas, high resources, 3-node Kafka (RF=3), persistent storage, zone spreading
```

Each overlay contains only the **differences** from the base. Kustomize merges the base + overlay at deploy time to produce the final manifests.

### How Kustomize Merging Works

```
BASE                              OVERLAY (prod)                    RESULT
────────────────────              ──────────────────                ──────────────────
Deployment: pega-web              patches/app-replicas.yaml:        Deployment: pega-web
  replicas: 1             +        replicas: 4              =        replicas: 4
  cpu request: 250m                cpu request: 1                    cpu request: 1
  memory request: 256Mi            memory request: 2Gi               memory request: 2Gi
```

You can preview the merged output for any environment:

```bash
# Preview the final manifests for a specific environment
kustomize build overlays/ops
kustomize build overlays/prod

# Compare two environments side by side
diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)
```

---

## Demo Scenarios

### Demo 1: GitOps in Action -- Push and Watch

**Goal:** Show that a single Git push automatically propagates across all environments.

1. Open the ArgoCD UI on a shared screen
2. Make a change to the base deployment (e.g., update the image tag):
   ```bash
   # Edit base/app/deployment.yaml
   # Change: image: nginx:1.25-alpine
   # To:     image: nginx:1.27-alpine
   ```
3. Commit and push:
   ```bash
   git add -A && git commit -m "Upgrade nginx to 1.27" && git push origin master
   ```
4. Watch the ArgoCD UI -- within ~3 minutes, ArgoCD detects the new commit and begins rolling out updated pods across OPS, SBX, TEST, IMPL, and TRNG
5. PROD shows **OutOfSync** and waits for manual approval

**Key takeaway:** One commit, one change in the base, and all environments update. PROD remains gated. If the change needs to be reverted, `git revert` rolls back all environments.

---

### Demo 2: Self-Healing

**Goal:** Show that ArgoCD automatically restores resources that are manually deleted or modified.

1. Delete a pod:
   ```bash
   kubectl delete pod -n test -l app=pega-web --wait=false
   ```
   ArgoCD detects the missing pod and the ReplicaSet recreates it within seconds.

2. Delete an entire deployment:
   ```bash
   kubectl delete deployment pega-web -n test
   ```
   ArgoCD detects the missing Deployment and recreates it from the Git-defined state.

**Key takeaway:** The desired state lives in Git, not in the cluster. Accidental deletions, unauthorized changes, or configuration drift are automatically corrected. This eliminates an entire class of incidents.

---

### Demo 3: Environment Comparison

**Goal:** Show how easy it is to understand what differs between environments.

1. In the ArgoCD UI, click `pega-ops` > "App Details"
   - Note: 1 replica, minimal CPU/memory
2. Click `pega-prod` > "App Details"
   - Note: 4 replicas, higher CPU/memory, persistent Kafka storage, zone topology constraints

Alternatively, compare via CLI:
```bash
diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)
```

**Key takeaway:** Environment differences are declarative and auditable. No need to SSH into clusters or compare running configs manually. The Git diff is the source of truth.

---

### Demo 4: Production Gating

**Goal:** Show how PROD is protected from automatic deployments.

1. After a Git push, notice that `pega-prod` shows **OutOfSync** (orange)
2. Click on `pega-prod` in the ArgoCD UI
3. Click **Sync** to review the pending changes
4. Review the diff -- ArgoCD shows exactly what will be created, modified, or deleted
5. Click **Synchronize** to approve the deployment

**Key takeaway:** PROD deployments require explicit human approval. This is enforced at the system level (in the Application manifest), not as a process that someone might skip. The diff view provides a built-in change review before anything touches production.

---

### Demo 5: Kustomize Under the Hood

**Goal:** Show how one base template serves all environments with minimal per-environment config.

```bash
# The shared base template
cat base/app/deployment.yaml

# A lightweight overlay (OPS: minimal)
cat overlays/ops/patches/app-replicas.yaml

# A production overlay (PROD: scaled up, zone-aware)
cat overlays/prod/patches/app-replicas.yaml

# The final merged output
kustomize build overlays/ops | grep -A 20 "kind: Deployment"
kustomize build overlays/prod | grep -A 30 "kind: Deployment"
```

**Key takeaway:** The base is maintained once. Each environment overlay is a small, focused patch containing only what differs. Updating a shared property (e.g., image version) requires changing one file, and all environments inherit the update.

---

## Quick Reference

| Task | Command |
|------|---------|
| List all ArgoCD applications | `kubectl get applications -n argocd` |
| Check pods in an environment | `kubectl get pods -n test` |
| Preview manifests for an env | `kustomize build overlays/test` |
| Compare two environments | `diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)` |
| Force ArgoCD to re-check Git | Click Refresh in the UI, or annotate: `argocd.argoproj.io/refresh: hard` |
| View ArgoCD server logs | `kubectl logs -n argocd deployment/argocd-server` |
| Retrieve admin password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |
| Tear down the entire demo | `kind delete cluster --name argocd-demo` |

---

## Cleanup

To remove the entire demo environment:

```bash
kind delete cluster --name argocd-demo
```

This deletes the cluster and all associated Docker containers. Nothing persists on the host. To run the demo again, start from Step 1 or use the included `./setup.sh` script.

---

## Why ArgoCD? (Discussion Points)

| Traditional Approach | GitOps with ArgoCD |
|---------------------|-------------------|
| Engineers run `kubectl apply` from their laptops | All changes go through Git with PR review and approval |
| No clear audit trail for deployments | Full Git history: who changed what, when, and why |
| Cluster configuration drifts silently from intended state | ArgoCD continuously monitors and corrects drift |
| Production deployments are manual, error-prone processes | Production deployments are reviewed diffs with one-click approval |
| Rollback means finding and reapplying old manifests | Rollback is `git revert` -- ArgoCD handles the rest |
| Managing N environments means N times the manual effort | One base template + N lightweight overlays via Kustomize |
| Environment parity is aspirational | Environment parity is enforced by the tooling |
