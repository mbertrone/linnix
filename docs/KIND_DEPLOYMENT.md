# Deploying Cognitod to Kind (Local Kubernetes)

This guide covers deploying cognitod to a local kind (Kubernetes in Docker) cluster for development and testing.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Step-by-Step Guide](#step-by-step-guide)
- [Using Custom Images](#using-custom-images)
- [Deployment vs DaemonSet](#deployment-vs-daemonset)
- [Accessing the API](#accessing-the-api)
- [Troubleshooting](#troubleshooting)
- [Development Workflow](#development-workflow)

---

## Prerequisites

### Required Tools

- **kind**: Version 0.20.0 or later
- **kubectl**: Compatible with your kind cluster version
- **Docker**: For building and running kind
- **Helm** (optional): For advanced deployments

### Verify Installation

```bash
# Check kind
kind version

# Check kubectl
kubectl version --client

# Check Docker
docker ps
```

### Create a Kind Cluster

If you don't have a kind cluster yet:

```bash
# Create a simple cluster
kind create cluster --name dev

# Or create with custom config (recommended for Linnix)
cat <<EOF | kind create cluster --name dev --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /sys/kernel/debug
    containerPath: /sys/kernel/debug
  - hostPath: /sys/kernel/btf
    containerPath: /sys/kernel/btf
EOF
```

**Note**: The custom config mounts kernel debugging interfaces needed for eBPF.

---

## Quick Start

Deploy using pre-built images from GitHub Container Registry:

```bash
# Ensure you're using the kind context
kubectl config use-context kind-dev

# Deploy all manifests
kubectl apply -f k8s/

# Check status
kubectl get daemonset linnix-agent
kubectl get pods -l app=linnix

# View logs
kubectl logs -l app=linnix -f
```

---

## Step-by-Step Guide

### 1. Switch to Kind Context

```bash
# List available contexts
kubectl config get-contexts

# Switch to your kind cluster
kubectl config use-context kind-dev
```

### 2. Deploy Linnix Components

```bash
# Create RBAC resources
kubectl apply -f k8s/rbac.yaml

# Create ConfigMap with configuration
kubectl apply -f k8s/configmap.yaml

# Deploy DaemonSet (or Deployment for testing)
kubectl apply -f k8s/daemonset.yaml
```

### 3. Verify Deployment

```bash
# Check DaemonSet status
kubectl get daemonset linnix-agent

# Check pods
kubectl get pods -l app=linnix -o wide

# Check logs
kubectl logs -l app=linnix --tail=50

# Check for errors
kubectl describe pod -l app=linnix
```

### 4. Test the API

```bash
# Port forward to access the API
kubectl port-forward daemonset/linnix-agent 3000:3000

# In another terminal, test endpoints
curl http://localhost:3000/healthz
curl http://localhost:3000/status | jq
curl http://localhost:3000/processes | jq
```

---

## Using Custom Images

### Building and Loading Images into Kind

When developing locally, you need to load your custom-built images into the kind cluster:

#### Step 1: Build the Image

```bash
# Build with branch tag
BRANCH=$(git branch --show-current)
docker build -t cognitod:${BRANCH} .

# Or build with a local tag
docker build -t cognitod:local .
```

#### Step 2: Load Image into Kind

```bash
# Load the image into your kind cluster
kind load docker-image cognitod:${BRANCH} --name dev

# Or if using 'local' tag
kind load docker-image cognitod:local --name dev

# Verify the image is loaded
docker exec -it dev-control-plane crictl images | grep cognitod
```

#### Step 3: Update Manifest to Use Local Image

Create a local override file `k8s/local-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: linnix-agent
  namespace: default
  labels:
    app: linnix
spec:
  replicas: 1
  selector:
    matchLabels:
      app: linnix
  template:
    metadata:
      labels:
        app: linnix
    spec:
      serviceAccountName: linnix-agent
      hostPID: true
      containers:
        - name: cognitod
          image: cognitod:local  # Your local image
          imagePullPolicy: Never  # Important: Don't try to pull
          securityContext:
            privileged: true
          volumeMounts:
            - name: config
              mountPath: /etc/linnix
              readOnly: true
            - name: sys-btf
              mountPath: /sys/kernel/btf/vmlinux
              readOnly: true
            - name: debugfs
              mountPath: /sys/kernel/debug
          resources:
            limits:
              memory: 512Mi
              cpu: 500m
            requests:
              memory: 128Mi
              cpu: 100m
          ports:
            - containerPort: 3000
              name: http
      volumes:
        - name: config
          configMap:
            name: linnix-config
        - name: sys-btf
          hostPath:
            path: /sys/kernel/btf/vmlinux
            type: File
        - name: debugfs
          hostPath:
            path: /sys/kernel/debug
            type: Directory
```

#### Step 4: Deploy the Local Image

```bash
# Apply RBAC and ConfigMap if not already done
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/configmap.yaml

# Deploy using local image
kubectl apply -f k8s/local-deployment.yaml

# Watch deployment rollout
kubectl rollout status deployment/linnix-agent
```

### Quick Script for Rebuild and Reload

```bash
#!/bin/bash
# save as: scripts/kind-deploy.sh

set -e

CLUSTER_NAME=${1:-dev}
IMAGE_TAG=${2:-local}

echo "Building cognitod:${IMAGE_TAG}..."
docker build -t cognitod:${IMAGE_TAG} .

echo "Loading image into kind cluster '${CLUSTER_NAME}'..."
kind load docker-image cognitod:${IMAGE_TAG} --name ${CLUSTER_NAME}

echo "Restarting deployment..."
kubectl rollout restart deployment/linnix-agent

echo "Waiting for rollout..."
kubectl rollout status deployment/linnix-agent

echo "✅ Deployment complete!"
kubectl get pods -l app=linnix
```

**Usage**:
```bash
chmod +x scripts/kind-deploy.sh
./scripts/kind-deploy.sh dev local
```

---

## Deployment vs DaemonSet

### DaemonSet (Production-like)

**Use when**: Testing production deployment behavior

```yaml
kind: DaemonSet
```

**Characteristics**:
- Runs on **every node** in the cluster
- Automatically scales with cluster size
- Matches production behavior for cluster-wide monitoring

**Deploy**:
```bash
kubectl apply -f k8s/daemonset.yaml
```

### Deployment (Development)

**Use when**: Rapid iteration and testing

```yaml
kind: Deployment
spec:
  replicas: 1
```

**Characteristics**:
- Runs a **single pod** (configurable)
- Faster iteration cycle
- Easier to debug and inspect logs
- Better for development

**Deploy**:
```bash
kubectl apply -f k8s/local-deployment.yaml
```

### Switching Between Them

```bash
# Delete DaemonSet
kubectl delete daemonset linnix-agent

# Deploy as Deployment
kubectl apply -f k8s/local-deployment.yaml

# Or vice versa
kubectl delete deployment linnix-agent
kubectl apply -f k8s/daemonset.yaml
```

---

## Accessing the API

### Port Forwarding

Forward the cognitod API to your local machine:

```bash
# For DaemonSet
kubectl port-forward daemonset/linnix-agent 3000:3000

# For Deployment
kubectl port-forward deployment/linnix-agent 3000:3000

# Or target a specific pod
kubectl port-forward $(kubectl get pod -l app=linnix -o name | head -1) 3000:3000
```

**Test endpoints**:
```bash
# Health check
curl http://localhost:3000/healthz

# System status
curl http://localhost:3000/status | jq

# Process list
curl http://localhost:3000/processes | jq

# Real-time event stream
curl -N http://localhost:3000/stream
```

### Using a Service (Optional)

Create a NodePort service for easier access:

```yaml
# k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: linnix-api
  namespace: default
spec:
  type: NodePort
  selector:
    app: linnix
  ports:
    - port: 3000
      targetPort: 3000
      nodePort: 30000
```

**Deploy**:
```bash
kubectl apply -f k8s/service.yaml

# Access via kind node IP
KIND_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dev-control-plane)
curl http://${KIND_IP}:30000/healthz
```

---

## Troubleshooting

### Image Not Found

**Symptom**:
```
Failed to pull image "cognitod:local": rpc error: code = Unknown desc = failed to pull and unpack image
```

**Solution**:
1. Ensure image is built: `docker images | grep cognitod`
2. Load into kind: `kind load docker-image cognitod:local --name dev`
3. Set `imagePullPolicy: Never` in manifest

### eBPF Loading Fails

**Symptom**:
```
Error: Failed to load eBPF program: Operation not permitted
```

**Solution**:
```bash
# Check if running privileged
kubectl get pod -l app=linnix -o jsonpath='{.items[0].spec.containers[0].securityContext}'

# Ensure privileged: true is set
kubectl patch deployment linnix-agent -p '{"spec":{"template":{"spec":{"containers":[{"name":"cognitod","securityContext":{"privileged":true}}]}}}}'
```

### BTF Not Available

**Symptom**:
```
Error: BTF not found at /sys/kernel/btf/vmlinux
```

**Solution**:
BTF may not be available in the kind node. Check kernel version:
```bash
docker exec dev-control-plane uname -r

# Kind uses the host kernel, check host BTF
ls -la /sys/kernel/btf/vmlinux
```

If BTF is missing on the host, you may need a kernel upgrade (5.4+ with CONFIG_DEBUG_INFO_BTF=y).

### Pod Stuck in Pending

**Symptom**:
```
NAME                            READY   STATUS    RESTARTS   AGE
linnix-agent-7d9c8b5f4b-xyz12   0/1     Pending   0          5m
```

**Solution**:
```bash
# Check events
kubectl describe pod -l app=linnix

# Common issues:
# - Node not ready
kubectl get nodes

# - Resource constraints
kubectl top nodes

# - Volume mount issues
kubectl get pv,pvc
```

### Viewing Detailed Logs

```bash
# Stream logs
kubectl logs -l app=linnix -f

# Previous container logs (if crashed)
kubectl logs -l app=linnix --previous

# All containers in pod
kubectl logs -l app=linnix --all-containers=true

# Last 100 lines with timestamps
kubectl logs -l app=linnix --tail=100 --timestamps
```

### Debug with Shell

```bash
# Exec into running pod
kubectl exec -it $(kubectl get pod -l app=linnix -o name | head -1) -- /bin/bash

# Check processes
ps aux | grep cognitod

# Check mounts
mount | grep -E 'btf|debug'

# Check eBPF programs
ls -la /usr/local/share/linnix/

# Test config
cat /etc/linnix/linnix.toml
```

---

## Development Workflow

### Rapid Iteration Cycle

```bash
# 1. Make code changes
vim cognitod/src/main.rs

# 2. Build new image
docker build -t cognitod:local .

# 3. Load into kind
kind load docker-image cognitod:local --name dev

# 4. Restart deployment
kubectl rollout restart deployment/linnix-agent

# 5. Watch logs
kubectl logs -l app=linnix -f
```

### Using Watch Mode

```bash
# Terminal 1: Watch pod status
watch -n 2 kubectl get pods -l app=linnix

# Terminal 2: Stream logs
kubectl logs -l app=linnix -f --tail=20

# Terminal 3: Port forward for testing
kubectl port-forward deployment/linnix-agent 3000:3000
```

### Testing Configuration Changes

```bash
# Edit ConfigMap
kubectl edit configmap linnix-config

# Or update from file
kubectl create configmap linnix-config \
  --from-file=linnix.toml=configs/linnix.toml \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart to pick up new config
kubectl rollout restart deployment/linnix-agent
```

### Cleanup

```bash
# Delete all Linnix resources
kubectl delete -f k8s/

# Or selectively
kubectl delete deployment linnix-agent
kubectl delete configmap linnix-config
kubectl delete serviceaccount linnix-agent
kubectl delete clusterrole linnix-agent
kubectl delete clusterrolebinding linnix-agent

# Delete kind cluster entirely
kind delete cluster --name dev
```

---

## Advanced Topics

### Multi-Node Kind Cluster

For testing DaemonSet behavior across multiple nodes:

```bash
cat <<EOF | kind create cluster --name dev --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

# Deploy DaemonSet
kubectl apply -f k8s/

# Verify one pod per node
kubectl get pods -l app=linnix -o wide
```

### Using Kind with Registry

Set up a local registry for faster image loading:

```bash
# Create registry
docker run -d --restart=always -p 5000:5000 --name kind-registry registry:2

# Connect registry to kind network
docker network connect kind kind-registry

# Build and push to local registry
docker build -t localhost:5000/cognitod:local .
docker push localhost:5000/cognitod:local

# Update manifest to use registry image
# image: localhost:5000/cognitod:local
```

### Persistent Storage

Add persistent volumes for cognitod data:

```yaml
volumes:
  - name: data
    hostPath:
      path: /var/lib/linnix
      type: DirectoryOrCreate
```

### Resource Limits Testing

Test behavior under resource constraints:

```yaml
resources:
  limits:
    memory: 128Mi  # Tight limit
    cpu: 100m
  requests:
    memory: 64Mi
    cpu: 50m
```

Monitor:
```bash
kubectl top pods -l app=linnix
```

---

## Quick Reference

```bash
# Build and load image
docker build -t cognitod:local . && kind load docker-image cognitod:local --name dev

# Deploy
kubectl apply -f k8s/rbac.yaml -f k8s/configmap.yaml -f k8s/local-deployment.yaml

# Check status
kubectl get pods -l app=linnix && kubectl logs -l app=linnix --tail=20

# Port forward and test
kubectl port-forward deployment/linnix-agent 3000:3000 &
curl http://localhost:3000/healthz

# Restart after changes
kubectl rollout restart deployment/linnix-agent

# Cleanup
kubectl delete -f k8s/ && kind delete cluster --name dev
```

---

## Related Documentation

- [Building Guide](BUILDING.md) - Build Docker images
- [Kubernetes README](../k8s/README.md) - Production Kubernetes deployment
- [Configuration Guide](wiki/Configuration-Guide.md) - Configure cognitod
- [Getting Started](wiki/Getting-Started.md) - General setup guide

---

## Questions or Issues?

- **Kind Issues**: https://github.com/kubernetes-sigs/kind/issues
- **Linnix Issues**: https://github.com/linnix-os/linnix/issues
- **Kubernetes Docs**: https://kubernetes.io/docs/
