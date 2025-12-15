#!/bin/bash
# kind-deploy.sh - Build, load, and deploy cognitod to kind cluster
#
# Usage:
#   ./scripts/kind-deploy.sh [cluster-name] [image-tag]
#   ./scripts/kind-deploy.sh dev local
#   ./scripts/kind-deploy.sh             # Uses defaults: dev, local

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${1:-dev}
IMAGE_TAG=${2:-local}
IMAGE_NAME="cognitod:${IMAGE_TAG}"
DEPLOYMENT_TYPE=${3:-deployment}  # deployment or daemonset

echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  Cognitod Kind Deployment Script      ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Cluster:    ${CLUSTER_NAME}"
echo "Image:      ${IMAGE_NAME}"
echo "Type:       ${DEPLOYMENT_TYPE}"
echo ""

# Check if kind cluster exists
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo -e "${RED}✗ Kind cluster '${CLUSTER_NAME}' not found${NC}"
    echo ""
    echo "Available clusters:"
    kind get clusters
    echo ""
    echo "Create a cluster with:"
    echo "  kind create cluster --name ${CLUSTER_NAME}"
    exit 1
fi
echo -e "${GREEN}✓ Kind cluster '${CLUSTER_NAME}' found${NC}"

# Check if kubectl context is correct
CURRENT_CONTEXT=$(kubectl config current-context)
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
    echo -e "${YELLOW}⚠ Switching kubectl context from '${CURRENT_CONTEXT}' to '${EXPECTED_CONTEXT}'${NC}"
    kubectl config use-context "${EXPECTED_CONTEXT}"
fi
echo -e "${GREEN}✓ Using context '${EXPECTED_CONTEXT}'${NC}"

# Build Docker image
echo ""
echo -e "${YELLOW}[1/5] Building ${IMAGE_NAME}...${NC}"
if docker build -t "${IMAGE_NAME}" . ; then
    echo -e "${GREEN}✓ Image built successfully${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

# Load image into kind
echo ""
echo -e "${YELLOW}[2/5] Loading image into kind cluster...${NC}"
if kind load docker-image "${IMAGE_NAME}" --name "${CLUSTER_NAME}"; then
    echo -e "${GREEN}✓ Image loaded into kind${NC}"
else
    echo -e "${RED}✗ Failed to load image${NC}"
    exit 1
fi

# Verify image is in kind
echo ""
echo -e "${YELLOW}[3/5] Verifying image in cluster...${NC}"
if docker exec "${CLUSTER_NAME}-control-plane" crictl images | grep -q "cognitod.*${IMAGE_TAG}"; then
    echo -e "${GREEN}✓ Image verified in cluster${NC}"
else
    echo -e "${RED}✗ Image not found in cluster${NC}"
    exit 1
fi

# Apply RBAC and ConfigMap if not exists
echo ""
echo -e "${YELLOW}[4/5] Applying Kubernetes resources...${NC}"

if ! kubectl get serviceaccount linnix-agent >/dev/null 2>&1; then
    echo "  • Creating RBAC resources..."
    kubectl apply -f k8s/rbac.yaml
else
    echo -e "  ${GREEN}✓ RBAC already exists${NC}"
fi

if ! kubectl get configmap linnix-config >/dev/null 2>&1; then
    echo "  • Creating ConfigMap..."
    kubectl apply -f k8s/configmap.yaml
else
    echo -e "  ${GREEN}✓ ConfigMap already exists${NC}"
fi

# Deploy or update
echo ""
echo -e "${YELLOW}[5/5] Deploying cognitod...${NC}"

if [ "$DEPLOYMENT_TYPE" = "daemonset" ]; then
    MANIFEST="k8s/daemonset.yaml"
    RESOURCE_TYPE="daemonset"
    RESOURCE_NAME="daemonset/linnix-agent"
else
    MANIFEST="k8s/local-deployment.yaml"
    RESOURCE_TYPE="deployment"
    RESOURCE_NAME="deployment/linnix-agent"
fi

# Check if already deployed
if kubectl get "${RESOURCE_TYPE}" linnix-agent >/dev/null 2>&1; then
    echo "  • Restarting existing ${RESOURCE_TYPE}..."
    kubectl rollout restart "${RESOURCE_NAME}"
else
    echo "  • Creating new ${RESOURCE_TYPE}..."
    kubectl apply -f "${MANIFEST}"
fi

# Wait for rollout
echo ""
echo -e "${YELLOW}Waiting for rollout...${NC}"
if kubectl rollout status "${RESOURCE_NAME}" --timeout=2m; then
    echo -e "${GREEN}✓ Rollout complete${NC}"
else
    echo -e "${RED}✗ Rollout failed${NC}"
    echo ""
    echo "Pod status:"
    kubectl get pods -l app=linnix
    echo ""
    echo "Recent logs:"
    kubectl logs -l app=linnix --tail=20
    exit 1
fi

# Show deployment status
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Deployment Successful! 🎉         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Pod status:"
kubectl get pods -l app=linnix -o wide
echo ""
echo "Next steps:"
echo "  • View logs:        kubectl logs -l app=linnix -f"
echo "  • Port forward:     kubectl port-forward ${RESOURCE_NAME} 3000:3000"
echo "  • Test API:         curl http://localhost:3000/healthz"
echo "  • Get status:       curl http://localhost:3000/status | jq"
echo "  • Stream events:    curl -N http://localhost:3000/stream"
echo ""
