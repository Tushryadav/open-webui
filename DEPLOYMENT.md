# Open WebUI Production Deployment Guide

## Architecture Overview

```
Internet
  ↓
nginx Ingress Controller (port 80/443)
  ↓
┌─────────────────── owui-app namespace ───────────────────┐
│  Open WebUI API (3 pods, HPA 3-10)                       │
│  LiteLLM Gateway (2 pods) → NVIDIA NIM API               │
└──────────────────────────────────────────────────────────┘
  ↓
┌─────────────────── owui-data namespace ──────────────────┐
│  PostgreSQL (CNPG, 3 instances)                          │
│  Redis Sentinel (3 pods)                                 │
│  Qdrant (1 pod, vector DB for RAG)                       │
│  Azure Blob Storage (external)                           │
└──────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Requirement | Version |
|---|---|
| Ubuntu | 22.04 LTS |
| K3s | latest |
| Helm | 3+ |
| CNPG Operator | 0.28.2+ |
| cert-manager | v1.14.0+ |
| NVIDIA NIM API key | from build.nvidia.com |
| Azure Storage Account | any tier |

### VM Specs (Single Node)

| Resource | Minimum | Recommended |
|---|---|---|
| vCPU | 4 | 8 |
| RAM | 8GB | 16GB |
| Disk | 50GB SSD | 100GB SSD |
| OS | Ubuntu 22.04 | Ubuntu 22.04 |

---

## Step 1 — Prepare the VM

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install tools
sudo apt install -y curl git jq openssl python3

# Open ports
sudo ufw allow 22
sudo ufw allow 80
sudo ufw allow 443
sudo ufw enable
```

---

## Step 2 — Install K3s

```bash
curl -sfL https://get.k3s.io | sh -

# Setup kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
export KUBECONFIG=~/.kube/config

# Add to bashrc so it persists
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

## Step 3 — Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.type=LoadBalancer
```

## Step 4 — Install CNPG Operator

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace

# add prometheus setup 
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/kube-prometheus-values.yaml \
  --wait

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --values monitoring/otel-collector-values.yaml

##Install Redis Exporter

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

helm install redis-exporter prometheus-community/prometheus-redis-exporter \
  --namespace owui-data \
  --set redisAddress="redis://owui-data-redis-0.owui-data-redis-headless.owui-data.svc.cluster.local:6379" \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.namespace=monitoring

kubectl apply -f monitoring/alertmanager-config.yaml

## Step 5 — Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Wait for all 3 pods Running

```
helm install owui-data . \
  --namespace owui-data \
  --values values.yaml \
  --set postgres.cnpg.monitoring.enablePodMonitor=true \
  --set gateway.enabled=false \
  --set api.replicaCount=0 \
  --set api.hpa.enabled=false \
  --set api.ingress.enabled=false \
  --set vllm.enabled=false \
  --set networkPolicies.enabled=false \
  --set ollama.enabled=false \
  --set "minio.image.tag=RELEASE.2025-04-22T22-12-26Z" & 

  kubectl get podmonitor -n owui-data

helm install owui-app . \
  --namespace owui-app \
  --values values-production.yaml \
  --set postgres.cnpg.enabled=false \
  --set redis.enabled=false \
  --set qdrant.enabled=false \
  --set minio.enabled=false \
  --set vllm.enabled=false \
  --set ollama.enabled=false \
  --set postgres.external.enabled=true \
  --set "postgres.external.url=postgresql://openwebui:openwebui@owui-data-postgres-rw.owui-data.svc.cluster.local:5432/openwebui" \
  --set redis.external.enabled=true \
  --set "redis.external.url=redis://owui-data-redis-sentinel.owui-data.svc.cluster.local:26379/0?sentinel=mymaster" \
  --set qdrant.external.enabled=true \
  --set "qdrant.external.url=http://owui-data-qdrant.owui-data.svc.cluster.local:6333" \
  --set minio.external.enabled=true \
  --set "minio.external.endpoint=http://owui-data-minio.owui-data.svc.cluster.local:9000"


kubectl patch svc ingress-nginx-controller \
  -n ingress-nginx \
  --type='merge' \
  -p '{"spec":{"externalIPs":["20.46.228.117"]}}'

kubectl patch svc traefik \
  -n kube-system \
  --type='merge' \
  -p '{"spec":{"type":"ClusterIP"}}'
  
  
kubectl get svc -n kube-system | grep traefik
kubectl get svc -n ingress-nginx
kubectl get pods -n owui-app -w
kubectl get svc -n ingress-nginx
curl -s http://openwebui.20.46.228.117.nip.io/health
kubectl get nodes
kubectl get pods -n cert-manager -w
kubectl get pods -n cnpg-system -w
kubectl get svc -n monitoring | grep grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 --address 0.0.0.0 &
echo "http://grafana.<YOUR-IP>.nip.io"
kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 --address 0.0.0.0 &
kubectl logs -n monitoring deployment/otel-collector | grep -i "open-webui\|otlp\|metric"



