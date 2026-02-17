# ArgoCD Cluster Registration

## Local Demo (Kind)

For the local demo, all 6 cluster secrets point to `https://kubernetes.default.svc` (the same Kind cluster). Each ArgoCD Application deploys to a different namespace (`pega-ops`, `pega-sbx`, etc.) to avoid collisions.

The cluster secrets are applied by `setup.sh`:

```bash
kubectl apply -f argocd/clusters/cluster-secrets.yaml
```

## Production (EKS)

In production, each environment runs on a dedicated EKS cluster in its own VPC. Instead of using cluster secrets with hardcoded credentials, use the ArgoCD CLI to register clusters:

```bash
# Register each EKS cluster with ArgoCD (run from the management cluster)
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-ops --name eks-ops
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-sbx --name eks-sbx
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-test --name eks-test
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-impl --name eks-impl
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-trng --name eks-trng
argocd cluster add arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-prod --name eks-prod
```

This creates the same cluster secrets automatically, but with proper IAM authentication and TLS configuration.

## How It Works

ArgoCD discovers clusters via Kubernetes Secrets labeled with `argocd.argoproj.io/secret-type: cluster`. The `name` field in the secret's `stringData` is what ArgoCD Application manifests reference in `destination.name`.

```
ArgoCD Application (app-ops.yaml)          Cluster Secret (eks-ops)
┌─────────────────────────────────┐        ┌───────────────────────────┐
│ destination:                    │        │ stringData:               │
│   name: eks-ops            ────────────► │   name: eks-ops           │
│   namespace: pega-ops           │        │   server: https://...     │
└─────────────────────────────────┘        └───────────────────────────┘
```
