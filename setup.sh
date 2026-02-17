#!/bin/bash
set -euo pipefail

CLUSTER_NAME="argocd-demo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  ArgoCD Multi-Cluster Demo Setup"
echo "========================================="
echo ""
echo "This creates a local Kind cluster that simulates"
echo "6 EKS environments, each with its own ArgoCD in production."
echo "For the demo, one shared ArgoCD instance manages all 6."

# ---- Step 1: Create Kind cluster ----
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[OK] Kind cluster '${CLUSTER_NAME}' already exists"
else
  echo "[1/8] Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml" --wait 60s
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ---- Step 2: Install ArgoCD ----
echo ""
echo "[2/8] Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s

# ---- Step 3: Patch ArgoCD server for NodePort access ----
echo ""
echo "[3/8] Exposing ArgoCD UI via NodePort..."
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
echo "[4/8] Retrieving ArgoCD admin password..."
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "========================================="
echo "  ArgoCD UI Credentials"
echo "========================================="
echo "  URL:      https://localhost:8443"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASS}"
echo "========================================="

# ---- Step 5: Install CRDs (Strimzi + Karpenter) ----
echo ""
echo "[5/8] Installing CRDs..."

# Strimzi Kafka CRDs
echo "  Installing Strimzi Kafka CRDs..."
kubectl apply -f https://strimzi.io/install/latest?namespace=default --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - || {
  echo "  [WARN] Strimzi CRD install had issues -- applying minimal CRDs for demo"
  kubectl apply -f https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/install/cluster-operator/040-Crd-kafka.yaml 2>/dev/null || true
  kubectl apply -f https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/install/cluster-operator/043-Crd-kafkatopic.yaml 2>/dev/null || true
}

# Karpenter CRDs (applied as empty CRDs for demo -- real clusters have Karpenter installed)
echo "  Installing Karpenter CRDs for demo..."
for crd in nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws; do
  kubectl get crd "${crd}" &>/dev/null && continue
  kubectl apply -f - <<EOF || true
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${crd}
spec:
  group: $(echo "${crd}" | cut -d. -f2-)
  names:
    kind: $(echo "${crd}" | cut -d. -f1 | sed 's/s$//' | sed 's/^./\U&/' | sed 's/pool/Pool/' | sed 's/nodeclass/NodeClass/' | sed 's/ec2/EC2/')
    plural: $(echo "${crd}" | cut -d. -f1)
    singular: $(echo "${crd}" | cut -d. -f1 | sed 's/s$//')
  scope: Cluster
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
EOF
done

# ---- Step 6: Create environment namespaces ----
echo ""
echo "[6/8] Creating environment namespaces..."
for ns in pega-ops pega-sbx pega-test pega-impl pega-trng pega-prod; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

# ---- Step 7: Register cluster secrets ----
echo ""
echo "[7/8] Registering cluster secrets (local demo -- all point to Kind cluster)..."
kubectl apply -f "${SCRIPT_DIR}/argocd/clusters/cluster-secrets.yaml"

# NOTE: Cluster secrets and app-of-apps are local demo conveniences only.
# In production, each EKS cluster runs its own ArgoCD instance and applies
# only its own Application manifest (e.g., app-prod.yaml). There is no
# cross-cluster management. See README.md for production setup instructions.

# ---- Step 8: Create AppProject ----
echo ""
echo "[8/8] Creating ArgoCD AppProject..."
kubectl apply -f "${SCRIPT_DIR}/argocd/project.yaml"

echo ""
echo "========================================="
echo "  Setup complete!"
echo "========================================="
echo ""
echo "Open https://localhost:8443 in your browser."
echo "(Accept the self-signed certificate warning)"
echo ""
echo "Next steps:"
echo "  1. Open the ArgoCD UI"
echo "  2. Run: kubectl apply -f argocd/app-of-apps.yaml"
echo "     (or apply individual apps from the argocd/ folder)"
echo "  3. Watch ArgoCD sync all 6 environments!"
echo ""
echo "Local demo architecture (one Kind cluster, namespace isolation):"
echo "  ArgoCD (Kind) --> pega-ops   (simulates eks-ops)"
echo "                --> pega-sbx   (simulates eks-sbx)"
echo "                --> pega-test  (simulates eks-test)"
echo "                --> pega-impl  (simulates eks-impl)"
echo "                --> pega-trng  (simulates eks-trng)"
echo "                --> pega-prod  (simulates eks-prod)"
echo ""
echo "Production: each EKS cluster runs its own ArgoCD instance."
echo "See README.md for production setup instructions."
