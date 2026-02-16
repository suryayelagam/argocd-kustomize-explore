# ArgoCD + Kustomize Demo Runbook

## What is this?

Imagine you have 6 toy boxes (OPS, SBX, TEST, IMPL, TRNG, PROD). Each toy box should have the same toys, but some boxes get bigger toys and more of them. Instead of putting toys in each box by hand, you write a list (Git) of what goes where, and a robot (ArgoCD) reads that list and fills the boxes for you. If someone takes a toy out, the robot puts it back. That's GitOps.

---

## The Cast of Characters

| Tool | What it does (ELI5) |
|------|---------------------|
| **ArgoCD** | The robot that watches your list (Git repo) and makes sure your Kubernetes cluster matches it. If something changes in Git, ArgoCD updates the cluster. If someone messes with the cluster, ArgoCD fixes it. |
| **Kustomize** | A copy machine with a "tweak" button. You write one set of files (the base), then say "for TEST, make 2 copies" and "for PROD, make 4 copies with more memory." No duplicating files everywhere. |
| **Kind** | A mini Kubernetes cluster that runs inside Docker on your laptop. It's like a practice sandbox -- everything runs locally. |
| **Strimzi** | Runs Apache Kafka (a message bus) on Kubernetes. Think of it like a post office inside your cluster. |
| **Karpenter** | Automatically adds/removes servers (nodes) based on demand. If your apps need more room, Karpenter gets more servers. If they're idle, it removes them. Like an elastic parking lot. |
| **Gitea** | A mini GitHub that runs inside the cluster (we replaced this with your real GitHub). |

---

## Prerequisites

Before you start, you need these installed:

```
brew install kubectl kind helm kustomize
```

And **Docker Desktop** running (the whale icon in your menu bar).

---

## Step-by-Step Setup

### Step 1: Start Docker Desktop

Open Docker Desktop from your Applications folder. Wait until the whale icon in the menu bar stops animating and says "Docker Desktop is running."

**Why?** Kind creates a Kubernetes cluster using Docker containers. No Docker = no cluster.

---

### Step 2: Create the Kind Cluster

```bash
kind create cluster --name argocd-demo --config kind-config.yaml --wait 60s
```

**What just happened?** You created a mini Kubernetes cluster on your laptop called `argocd-demo`. The `kind-config.yaml` tells it to open port 8443 so you can access ArgoCD's web UI later.

**Verify it worked:**
```bash
kubectl cluster-info --context kind-argocd-demo
```
You should see "Kubernetes control plane is running at..."

---

### Step 3: Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

**What just happened?** You created a room called `argocd` in your cluster and installed the ArgoCD robot in it. ArgoCD is just a bunch of pods (containers) running inside Kubernetes.

**Wait for it to be ready:**
```bash
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
```

This waits until ArgoCD's web server is up and running. Takes about 30-60 seconds.

---

### Step 4: Expose the ArgoCD UI

```bash
kubectl patch svc argocd-server -n argocd -p '{
  "spec": {
    "type": "NodePort",
    "ports": [{"name": "https", "port": 443, "targetPort": 8080, "nodePort": 30443}]
  }
}'
```

**What just happened?** By default, ArgoCD's web page is hidden inside the cluster. This command punches a hole so your browser can reach it at `https://localhost:8443`.

---

### Step 5: Get the Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**What just happened?** ArgoCD generates a random password when it's installed and stores it as a Kubernetes Secret. This command reads and decodes it.

**Write it down:**
- URL: `https://localhost:8443`
- Username: `admin`
- Password: (the output from above)

Open the URL in your browser. Accept the self-signed certificate warning. Log in.

---

### Step 6: Install the CRDs (Custom Resource Definitions)

```bash
# Strimzi (Kafka) CRDs
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

**What just happened?** CRDs are like teaching Kubernetes new words. Kubernetes doesn't know what a "Kafka" or "NodePool" is by default. These CRDs say "Hey Kubernetes, here's what a Kafka object looks like" so it can store them. We're not running the actual operators (Strimzi/Karpenter) -- just teaching Kubernetes the vocabulary so ArgoCD can manage the resources.

---

### Step 7: Create the Environment Namespaces

```bash
for ns in ops sbx test impl trng prod; do
  kubectl create namespace $ns
done
```

**What just happened?** Namespaces are like folders in your cluster. Each environment gets its own folder so they don't step on each other. OPS stuff stays in `ops`, PROD stuff stays in `prod`.

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

**What just happened?** You told ArgoCD: "Hey, here are 6 applications. Each one lives in a different folder in my Git repo. Go watch those folders and deploy whatever you find." Each Application manifest says:
- **Where to look:** your GitHub repo + a specific path (e.g., `overlays/ops`)
- **Where to deploy:** which namespace in the cluster
- **How to sync:** automatically or manually

---

### Step 9: Watch the Magic

Go to the ArgoCD UI at `https://localhost:8443`. You should see 6 application tiles:

```
pega-ops    pega-sbx    pega-test    pega-impl    pega-trng    pega-prod
```

- **Green (Synced + Healthy):** ArgoCD deployed everything and it's running fine
- **Yellow (Progressing):** ArgoCD is still deploying / waiting for pods
- **Orange (OutOfSync):** The cluster doesn't match Git yet
- **Red (Degraded):** Something is broken

Click on any app to see the resource tree:
```
Application
  └── Deployment (pega-web)
       └── ReplicaSet
            └── Pod (running!)
  └── Service
  └── ConfigMap
  └── Ingress
  └── Kafka (Strimzi)
  └── KafkaTopic
  └── NodePool (Karpenter)
  └── EC2NodeClass
```

---

## Understanding the Project Structure

### The Base (the template)

```
base/
├── app/          <- The web application (Deployment, Service, ConfigMap, Ingress)
├── strimzi/      <- Kafka cluster and topics
└── karpenter/    <- Node scaling rules
```

This is like a blank form. It has everything but with default values.

### The Overlays (the customizations)

```
overlays/
├── ops/          <- Fill in the form for OPS: 1 replica, small resources
├── sbx/          <- Fill in the form for SBX: 1 replica, spot instances
├── test/         <- Fill in the form for TEST: 2 replicas, medium resources
├── impl/         <- Fill in the form for IMPL: 2 replicas, 3 Kafka brokers
├── trng/         <- Fill in the form for TRNG: 2 replicas, medium resources
└── prod/         <- Fill in the form for PROD: 4 replicas, big resources, persistent storage
```

Each overlay says "take the base, but change these specific things." No copy-pasting entire files.

### How Kustomize works (the simplest explanation)

```
BASE (shared template)          OVERLAY (per-environment tweaks)
─────────────────────           ────────────────────────────────
Deployment: pega-web     +      replicas: 4              =    PROD Deployment with 4 replicas
  replicas: 1                   cpu: 2 cores                  and 2 CPU cores
  cpu: 250m                     memory: 4Gi                   and 4Gi memory
  memory: 256Mi
```

You write the base once. Each overlay only contains what's DIFFERENT. Kustomize merges them together.

**Try it yourself:**
```bash
# See what OPS would look like (1 replica, small)
kustomize build overlays/ops

# See what PROD would look like (4 replicas, big)
kustomize build overlays/prod

# Compare them side by side
diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)
```

---

## Demo Scenarios

### Demo 1: "Push a change, watch it roll out everywhere"

This is the money shot. Shows GitOps in action.

**What to do:**
1. Open the ArgoCD UI so your audience can see it
2. Edit a file (e.g., change the nginx image tag):
   ```bash
   # In base/app/deployment.yaml, change:
   #   image: nginx:1.25-alpine
   # to:
   #   image: nginx:1.27-alpine
   ```
3. Commit and push:
   ```bash
   git add -A && git commit -m "Upgrade nginx to 1.27" && git push origin master
   ```
4. Watch the ArgoCD UI -- within 3 minutes, all auto-sync environments (OPS, SBX, TEST, IMPL, TRNG) will detect the change and start rolling out new pods
5. PROD will show **OutOfSync** with an orange indicator -- it's waiting for someone to click "Sync"

**What to tell your principal engineer:**
> "I pushed one commit. ArgoCD automatically rolled out the change to 5 environments.
> PROD is protected -- it requires a manual sync click. No one can accidentally deploy to PROD.
> If I revert the commit in Git, ArgoCD will roll back all environments too."

---

### Demo 2: "Self-healing -- ArgoCD fixes things that break"

**What to do:**
1. Delete a pod manually:
   ```bash
   kubectl delete pod -n test -l app=pega-web --wait=false
   ```
2. Watch the ArgoCD UI -- within seconds, it detects the missing pod and recreates it
3. Try something bigger -- delete the entire deployment:
   ```bash
   kubectl delete deployment pega-web -n test
   ```
4. ArgoCD will recreate the entire deployment automatically

**What to tell your principal engineer:**
> "Someone could accidentally run kubectl delete in production. With ArgoCD's self-heal,
> the desired state is always in Git. ArgoCD puts it back within seconds.
> No pager. No incident. The cluster heals itself."

---

### Demo 3: "Environment differences at a glance"

**What to do:**
1. Click on `pega-ops` in ArgoCD UI, then click "App Details"
   - Show: 1 replica, small resources
2. Click on `pega-prod` in ArgoCD UI, then click "App Details"
   - Show: 4 replicas, large resources, persistent Kafka storage
3. Click "Diff" tab to see what would change if you synced

**What to tell your principal engineer:**
> "Every environment is defined in Git. Want to know the difference between TEST and PROD?
> Look at the Git diff. No logging into servers. No comparing configs manually.
> The Git history IS the audit trail."

---

### Demo 4: "Manual PROD sync with approval"

**What to do:**
1. Notice `pega-prod` shows OutOfSync (orange)
2. Click on it
3. Click "Sync" button
4. Review the diff (shows exactly what will change)
5. Click "Synchronize" to approve

**What to tell your principal engineer:**
> "PROD never auto-deploys. A human has to review the diff and click Sync.
> This is built into the ArgoCD Application config -- not a process someone can forget.
> It's enforced by the system."

---

### Demo 5: "Show what Kustomize does under the hood"

Run these in your terminal while sharing your screen:

```bash
# Show the base (shared template)
echo "=== BASE ===" && cat base/app/deployment.yaml

# Show a small overlay patch
echo "=== OPS PATCH ===" && cat overlays/ops/patches/app-replicas.yaml

# Show a big overlay patch
echo "=== PROD PATCH ===" && cat overlays/prod/patches/app-replicas.yaml

# Show the final merged result for OPS
echo "=== FINAL OPS OUTPUT ===" && kustomize build overlays/ops | grep -A5 "kind: Deployment"

# Show the final merged result for PROD
echo "=== FINAL PROD OUTPUT ===" && kustomize build overlays/prod | grep -A5 "kind: Deployment"
```

**What to tell your principal engineer:**
> "We maintain ONE base template. Each environment only overrides what's different.
> OPS gets 1 replica with 100m CPU. PROD gets 4 replicas with 1 CPU and zone spreading.
> If we need to update the image, we change it in ONE place (base) and all environments get it."

---

## Quick Reference: Key Commands

| What | Command |
|------|---------|
| Check all apps | `kubectl get applications -n argocd` |
| Check pods in an env | `kubectl get pods -n test` |
| See what ArgoCD would deploy | `kustomize build overlays/test` |
| Compare two environments | `diff <(kustomize build overlays/ops) <(kustomize build overlays/prod)` |
| Force ArgoCD to re-check Git | Refresh button in the UI (or add annotation `argocd.argoproj.io/refresh: hard`) |
| See ArgoCD logs | `kubectl logs -n argocd deployment/argocd-server` |
| Get ArgoCD password again | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |
| Delete everything and start over | `kind delete cluster --name argocd-demo` |

---

## Cleanup

When you're done with the demo:

```bash
kind delete cluster --name argocd-demo
```

That's it. Everything is gone. Docker containers removed. Your laptop is clean. Next time you want to demo, just run through the steps again (or use `./setup.sh`).

---

## Why ArgoCD? (Cheat Sheet for the Conversation)

| Without ArgoCD | With ArgoCD |
|---------------|-------------|
| Someone runs `kubectl apply` from their laptop | Changes go through Git (PR review, approval) |
| "Who deployed this?" -- nobody knows | Git history shows who, what, when, why |
| Cluster and Git drift apart silently | ArgoCD alerts on drift and auto-fixes |
| PROD deploy is a scary manual process | PROD deploy is a reviewed, one-click sync |
| Rollback = "does anyone have the old YAML?" | Rollback = `git revert` and ArgoCD handles it |
| 6 environments = 6x the manual work | 6 environments = 1 base + 6 small overlays |
| "Works on my cluster" | Declarative config in Git = reproducible everywhere |
