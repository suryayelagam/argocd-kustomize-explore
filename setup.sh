#!/bin/bash
set -euo pipefail

CLUSTER_NAME="argocd-demo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  ArgoCD + Kustomize Demo Setup"
echo "========================================="

# ---- Step 1: Create Kind cluster ----
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[OK] Kind cluster '${CLUSTER_NAME}' already exists"
else
  echo "[1/5] Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml" --wait 60s
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ---- Step 2: Install ArgoCD ----
echo ""
echo "[2/5] Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s

# ---- Step 3: Patch ArgoCD server for NodePort access ----
echo ""
echo "[3/5] Exposing ArgoCD UI via NodePort..."
kubectl patch svc argocd-server -n argocd -p '{
  "spec": {
    "type": "NodePort",
    "ports": [
      {
        "name": "https",
        "port": 443,
        "targetPort": 8080,
        "nodePort": 30443
      }
    ]
  }
}'

# ---- Step 4: Get admin password ----
echo ""
echo "[4/5] Retrieving ArgoCD admin password..."
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "========================================="
echo "  ArgoCD UI Credentials"
echo "========================================="
echo "  URL:      https://localhost:8443"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASS}"
echo "========================================="

# ---- Step 5: Create namespaces ----
echo ""
echo "[5/5] Creating environment namespaces..."
for ns in ops sbx test impl trng prod; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "Setup complete! Open https://localhost:8443 in your browser."
echo "(Accept the self-signed certificate warning)"
echo ""
echo "Next steps:"
echo "  1. Open the ArgoCD UI"
echo "  2. Run: kubectl apply -f argocd/app-of-apps.yaml"
echo "     (or apply individual apps from the argocd/ folder)"
echo "  3. Watch ArgoCD sync all 6 environments!"
