# ArgoCD Cluster Registration

## Local Demo (Kind)

For the local demo, all 6 cluster secrets point to `https://kubernetes.default.svc` (the same Kind cluster). Each ArgoCD Application deploys to a different namespace (`pega-ops`, `pega-sbx`, etc.) to simulate separate clusters.

The cluster secrets are applied by `setup.sh`:

```bash
kubectl apply -f argocd/clusters/cluster-secrets.yaml
```

**These cluster secrets are a local demo convenience only.** They allow one shared ArgoCD instance to simulate deploying to 6 separate clusters.

## Production (EKS)

In production, each EKS cluster runs its own ArgoCD instance. There is no central hub or cross-cluster management.

Each cluster's ArgoCD deploys only to itself (`https://kubernetes.default.svc`), so **cluster secrets are not needed in production**. Each cluster simply:

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Apply the project and this cluster's Application
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/app-prod.yaml   # or app-ops.yaml, etc.
```

## How It Works (Local Demo)

ArgoCD discovers clusters via Kubernetes Secrets labeled with `argocd.argoproj.io/secret-type: cluster`. The `name` field in the secret's `stringData` is what ArgoCD Application manifests reference in `destination.name`.

```
ArgoCD Application (app-ops.yaml)          Cluster Secret (eks-ops)
┌─────────────────────────────────┐        ┌───────────────────────────┐
│ destination:                    │        │ stringData:               │
│   name: eks-ops            ────────────► │   name: eks-ops           │
│   namespace: pega-ops           │        │   server: https://...     │
└─────────────────────────────────┘        └───────────────────────────┘
```

This mechanism is only used in the local demo. In production, ArgoCD deploys in-cluster and `destination.server` points to `https://kubernetes.default.svc`.
