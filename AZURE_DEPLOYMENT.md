# Step-by-Step Deployment Guide — Azure VM

## Prerequisites

- Azure account with an active subscription
- Azure CLI installed locally (`az --version`)
- Domain name OR use `nip.io` for testing
- NVIDIA NIM API key from [build.nvidia.com](https://build.nvidia.com)
- Azure Storage Account + container created

---

## Step 1 — Create the Azure VM

```bash
# Login to Azure
az login

# Create resource group
az group create \
  --name owui-rg \
  --location eastus

# Create VM
az vm create \
  --resource-group owui-rg \
  --name owui-vm \
  --image Ubuntu2204 \
  --size Standard_D4s_v3 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --os-disk-size-gb 100 \
  --os-disk-caching ReadWrite

# Open required ports
az vm open-port \
  --resource-group owui-rg \
  --name owui-vm \
  --port 80 --priority 100

az vm open-port \
  --resource-group owui-rg \
  --name owui-vm \
  --port 443 --priority 101

az vm open-port \
  --resource-group owui-rg \
  --name owui-vm \
  --port 3000 --priority 102

# Get public IP
az vm show \
  --resource-group owui-rg \
  --name owui-vm \
  --show-details \
  --query publicIps -o tsv
```

> **VM Spec:** Standard_D4s_v3 = 4 vCPU / 16GB RAM / 100GB disk — minimum for full stack.

SSH into the VM:

```bash
ssh azureuser@<YOUR-PUBLIC-IP>
```

---

## Step 2 — Prepare the VM

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install required tools
sudo apt install -y curl git jq openssl python3 unzip

# Verify
curl --version && git --version && jq --version
```

---

## Step 3 — Install K3s

```bash
curl -sfL https://get.k3s.io | sh -

# Setup kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc

# Verify node is Ready
kubectl get nodes
# Expected output:
# NAME     STATUS   ROLES                  AGE   VERSION
# owui-vm  Ready    control-plane,master   30s   v1.x.x
```

---

## Step 4 — Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version
```

---

## Step 5 — Install CNPG Operator

CloudNativePG operator manages the PostgreSQL cluster.

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace

# Wait until operator pod is Running
kubectl get pods -n cnpg-system -w
# Expected: cloudnative-pg-xxx   1/1   Running
```

---

## Step 6 — Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Wait for all 3 pods Running
kubectl get pods -n cert-manager -w
# Expected: 3 pods all 1/1 Running
```

---

## Step 7 — Install nginx Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.type=LoadBalancer

# Wait for pod ready
kubectl get pods -n ingress-nginx -w
# Expected: ingress-nginx-controller-xxx   1/1   Running
```

Patch with your VM's public IP (K3s doesn't have a cloud LB):

```bash
kubectl patch svc ingress-nginx-controller \
  -n ingress-nginx \
  --type='merge' \
  -p '{"spec":{"externalIPs":["<YOUR-PUBLIC-IP>"]}}'

# Disable Traefik (K3s default) so nginx owns port 80
  kubectl patch svc traefik \
    -n kube-system \
    --type='merge' \
    -p '{"spec":{"type":"ClusterIP"}}'

# Verify nginx has the external IP
kubectl get svc -n ingress-nginx
# Expected: EXTERNAL-IP = <YOUR-PUBLIC-IP>
```

---

## Step 8 — Create Azure Blob Storage

```bash
# Create storage account
az storage account create \
  --name owuistorage \
  --resource-group owui-rg \
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2

# Create container
az storage container create \
  --name openwebui \
  --account-name owuistorage \
  --public-access off

# Get storage key — save this
az storage account keys list \
  --account-name owuistorage \
  --resource-group owui-rg \
  --query "[0].value" -o tsv
```

---

## Step 9 — Clone the Repository

```bash
cd ~
git clone https://github.com/Tushryadav/open-webui.git
cd open-webui
```

---

## Step 10 — Update Values File

```yaml
api:
  ingress:
    hosts:
      - host: "openwebui.<YOUR-PUBLIC-IP>.nip.io"   # e.g. openwebui.20.46.228.117.nip.io
        paths:
          - path: /
            pathType: Prefix
    tls: []

azure:
  storageEndpoint: "https://owuistorage.blob.core.windows.net"
  storageKey: "<key-from-step-8>"
  storageContainer: "openwebui"

gateway:
  masterKey: "sk-<generate-strong-key>"             # openssl rand -hex 32
  nvidiaApiKey: "nvapi-<your-nvidia-key>"
  openaiApiKey: ""
  anthropicApiKey: ""
  image:
    repository: ghcr.io/berriai/litellm
    tag: main-v1.85.1                               # pinned stable tag
    pullPolicy: Always

postgres:
  cnpg:
    monitoring:
      enablePodMonitor: false
```

Generate a strong master key:

```bash
openssl rand -hex 32
```

---

## Step 11 — Create Namespaces

```bash
kubectl create namespace owui-app
kubectl create namespace owui-data
kubectl create namespace monitoring
```

---

## Step 12 — Validate Helm Chart

```bash
cd ~/open-webui/helm

helm template owui-data . \
  --namespace owui-data \
  --values values-production.yaml > /dev/null && echo "YAML OK"
```

---

## Step 13 — Deploy Data Layer

```bash
cd ~/open-webui/helm

helm install owui-data . \
  --namespace owui-data \
  --values values-production.yaml \
  --set gateway.enabled=false \
  --set api.replicaCount=0 \
  --set api.hpa.enabled=false \
  --set api.ingress.enabled=false \
  --set vllm.enabled=false \
  --set ollama.enabled=false \
  --set networkPolicies.enabled=false \
  --set "minio.image.tag=RELEASE.2025-04-22T22-12-26Z"

# Watch pods
kubectl get pods -n owui-data -w
```

Wait until ALL pods show Running:

```
owui-data-postgres-1    1/1  Running
owui-data-postgres-2    1/1  Running
owui-data-postgres-3    1/1  Running
owui-data-redis-0       2/2  Running
owui-data-redis-1       2/2  Running
owui-data-redis-2       2/2  Running
owui-data-qdrant-0      1/1  Running
owui-data-minio-0       1/1  Running
```

---

## Step 14 — Verify Data Layer

```bash
# Postgres cluster healthy
kubectl get cluster -n owui-data
# Expected: STATUS = Cluster in healthy state

# Redis sentinel working
kubectl exec -n owui-data owui-data-redis-0 -c sentinel -- \
  redis-cli -p 26379 sentinel masters | grep -E "name|flags|num-slaves"

# Qdrant healthy
kubectl port-forward -n owui-data owui-data-qdrant-0 6333:6333 &
sleep 2
curl -s http://localhost:6333/healthz
kill %1
# Expected: healthz check passed

# MinIO healthy
kubectl exec -n owui-data owui-data-minio-0 -- \
  curl -s http://localhost:9000/minio/health/live
# Expected: empty = 200 OK
```

---

## Step 15 — Get Postgres Credentials

```bash
PG_USER=$(kubectl get secret owui-data-postgres-app -n owui-data \
  -o jsonpath='{.data.username}' | base64 -d)

PG_PASS=$(kubectl get secret owui-data-postgres-app -n owui-data \
  -o jsonpath='{.data.password}' | base64 -d)

PG_DB=$(kubectl get secret owui-data-postgres-app -n owui-data \
  -o jsonpath='{.data.dbname}' | base64 -d)

echo "User: $PG_USER"
echo "Pass: $PG_PASS"
echo "DB:   $PG_DB"
```

Save these — needed in the next step.

---

## Step 16 — Deploy App Layer

```bash
cd ~/open-webui/helm

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
  --set "postgres.external.url=postgresql://${PG_USER}:${PG_PASS}@owui-data-postgres-rw.owui-data.svc.cluster.local:5432/${PG_DB}" \
  --set redis.external.enabled=true \
  --set "redis.external.url=redis://owui-data-redis-sentinel.owui-data.svc.cluster.local:26379/0?sentinel=mymaster" \
  --set qdrant.external.enabled=true \
  --set "qdrant.external.url=http://owui-data-qdrant.owui-data.svc.cluster.local:6333"

# Watch pods
kubectl get pods -n owui-app -w
```

Wait until ALL pods show Running:

```
owui-app-open-webui-production-api-xxx   1/1  Running  (x3)
owui-app-inference-gateway-xxx           1/1  Running  (x2)
```

---

## Step 17 — Install Monitoring Stack

```bash
cd ~/open-webui/helm

# Install kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update 
 
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/kube-prometheus-values.yaml \
  --wait

helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --values monitoring/otel-collector-values.yaml

bash ~/open-webui/monitoring/apply-monitoring.sh

# Wait for all monitoring pods
kubectl get pods -n monitoring -w
kubectl get pods -n monitoring | grep otel
kubectl get servicemonitor -n monitoring
kubectl get prometheusrule -n monitoring
```

---


## Step 23 — Install ArgoCD

```bash
kubectl create namespace argocd
 
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
 
# Wait for argocd-server to be ready
kubectl wait --namespace argocd \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=180s

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/notifications/install.yaml

curl -sSL -o /tmp/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /tmp/argocd
sudo mv /tmp/argocd /usr/local/bin/argocd

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD password: $ARGOCD_PASSWORD"   

kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0 &
sleep 3

argocd login localhost:8080 \
  --username admin \
  --password $ARGOCD_PASSWORD \
  --insecure

ARGOCD_TOKEN=$(argocd account generate-token --account admin)
echo "ArgoCD token: $ARGOCD_TOKEN" 

# Adopt owui-data
argocd app create owui-data \
  --repo https://github.com/Tushryadav/open-webui.git \
  --path helm \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace owui-data \
  --revision main \
  --values values-production.yaml \
  --helm-set gateway.enabled=false \
  --helm-set api.replicaCount=0 \
  --helm-set api.hpa.enabled=false \
  --helm-set api.ingress.enabled=false \
  --helm-set vllm.enabled=false \
  --helm-set ollama.enabled=false \
  --helm-set networkPolicies.enabled=false \
  --sync-policy none \
  --upsert
 
# Adopt owui-app
argocd app create owui-app \
  --repo https://github.com/Tushryadav/open-webui.git \
  --path helm \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace owui-app \
  --revision main \
  --values values-production.yaml \
  --helm-set postgres.cnpg.enabled=false \
  --helm-set redis.enabled=false \
  --helm-set qdrant.enabled=false \
  --helm-set minio.enabled=false \
  --helm-set vllm.enabled=false \
  --helm-set ollama.enabled=false \
  --helm-set postgres.external.enabled=true \
  --helm-set "postgres.external.url=postgresql://${PG_USER}:${PG_PASS}@owui-data-postgres-rw.owui-data.svc.cluster.local:5432/${PG_DB}" \
  --helm-set redis.external.enabled=true \
  --helm-set "redis.external.url=redis://owui-data-redis-sentinel.owui-data.svc.cluster.local:26379/0?sentinel=mymaster" \
  --helm-set qdrant.external.enabled=true \
  --helm-set "qdrant.external.url=http://owui-data-qdrant.owui-data.svc.cluster.local:6333" \
  --sync-policy none \
  --upsert

argocd app list
argocd app set owui-app --sync-policy automated --self-heal --auto-prune

#Build & deploy the AI self-healing webhook

cd ~/open-webui/webhook
docker build -t ai-webhook:latest .
# Import directly into K3s containerd — skips the registry entirely
docker save ai-webhook:latest | sudo k3s ctr images import -

# Confirm K3s can see it
sudo k3s ctr images list | grep ai-webhook

kubectl create secret generic ai-webhook-secrets \
  --namespace owui-app \
  --from-literal=NVIDIA_API_KEY="nvapi-<your-key>" \
  --from-literal=ARGOCD_TOKEN="$ARGOCD_TOKEN" \
  --from-literal=SMTP_USER="your@gmail.com" \
  --from-literal=SMTP_PASSWORD="your-gmail-app-password" \
  --from-literal=ALERT_EMAIL_TO="oncall@yourdomain.com"

sed -i 's|image: <your-registry>/ai-webhook:latest|image: ai-webhook:latest|' \
  ~/open-webui/helm/templates/ai-webhook-deployment.yaml

sed -i 's|imagePullPolicy: Always|imagePullPolicy: Never|' \
  ~/open-webui/helm/templates/ai-webhook-deployment.yaml

kubectl apply -f ~/open-webui/helm/templates/ai-webhook-deployment.yaml

# Verify
kubectl get pods -n owui-app -l app=ai-webhook
kubectl logs -n owui-app deploy/ai-webhook

# All namespaces healthy
echo "=== owui-app ===" && kubectl get pods -n owui-app
echo "=== owui-data ===" && kubectl get pods -n owui-data
echo "=== monitoring ===" && kubectl get pods -n monitoring

# HTTP health check
curl -s http://openwebui.<YOUR-PUBLIC-IP>.nip.io/health
# Expected: {"status":true}

# API started correctly
kubectl logs -n owui-app deployment/owui-app-open-webui-production-api \
  | grep "startup complete"

# LiteLLM gateway up
kubectl logs -n owui-app deployment/owui-app-inference-gateway \
  | grep -i "litellm\|started\|proxy"

# Webhook healthy
curl -s http://$(kubectl get svc ai-webhook -n owui-app \
  -o jsonpath='{.spec.clusterIP}'):8000/healthz
# Expected: {"status":"ok"}
  
## Teardown

```bash
helm uninstall owui-app -n owui-app
helm uninstall owui-data -n owui-data
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall otel-collector -n monitoring
kubectl delete pvc --all -n owui-data
kubectl delete namespace owui-app owui-data monitoring

# Delete Azure resources
az group delete --name owui-rg --yes --no-wait
```
---

## Troubleshooting

| Issue | Fix |
|---|---|
| `ImagePullBackOff` on MinIO | Add `--set "minio.image.tag=RELEASE.2025-04-22T22-12-26Z"` |
| Gateway `OOMKilled` | Edit `gateway-deployment.yaml` memory limit to `2Gi` |
| `Unsupported storage provider: S3` | Set `STORAGE_PROVIDER=azure` in extraEnv |
| `404 page not found` in browser | Patch Traefik to ClusterIP, patch nginx with externalIPs |
| Ingress `ADDRESS` pending | `kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='merge' -p '{"spec":{"externalIPs":["<IP>"]}}'` |
| API pods not ready | Increase `initialDelaySeconds` to `120` for liveness probe |
| CNPG `no matches for kind Cluster` | Install CNPG operator first (Step 5) |
| `cannot re-use a name` on helm install | Run `helm uninstall <name> -n <namespace>` first |
| `must be a DNS name, not an IP` | Use `<ip>.nip.io` format for host |
| Postgres secret not found in owui-app | Copy secret: `kubectl get secret owui-data-postgres-app -n owui-data -o json \| kubectl apply -n owui-app -f -` |
