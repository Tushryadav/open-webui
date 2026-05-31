#!/bin/bash
# install-deps.sh
# Run once on a fresh Azure VM after SSH in
# Does NOT create any Azure resources
# Usage: bash install-deps.sh

set -e
echo "=== Installing dependencies ==="

# ── System packages ──────────────────────────────────────────────────────
sudo apt-get update -y && sudo apt upgrade -y
sudo apt-get install -y curl git jq openssl unzip ca-certificates gnupg

# ── Docker ───────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER   
    echo "Docker installed — re-login or run: newgrp docker"
else
    echo "Docker already installed: $(docker --version)"
fi

# ── K3s ──────────────────────────────────────────────────────────────────
if ! command -v k3s &>/dev/null; then
    curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
    export KUBECONFIG=~/.kube/config
    echo "K3s installed"
else
    echo "K3s already installed"
fi

# ── kubectl ───────────────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl && sudo mv kubectl /usr/local/bin/
    echo "kubectl installed"
else
    echo "kubectl already installed: $(kubectl version --client --short 2>/dev/null)"
fi

# ── Helm ──────────────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "Helm installed"
else
    echo "Helm already installed: $(helm version --short)"
fi

# ── cnpg ──────────────────────────────────────────────────────────────────
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace

# ──cert-manager ──────────────────────────────────────────────────────────────────

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Wait for all 3 pods Running
kubectl get pods -n cert-manager -w

# ──nginx Ingress Controller ──────────────────────────────────────────────────────────────────
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \s
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.type=LoadBalancer

# Wait for pod ready
```bash
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system --timeout=120s
```

# ──create namespace ──────────────────────────────────────────────────────────────────
kubectl create namespace owui-app
kubectl create namespace owui-data
kubectl create namespace monitoring

# Install kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update 

## Step 23 — Install ArgoCD

kubectl create namespace argocd
 
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/notifications/install.yaml

curl -sSL -o /tmp/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /tmp/argocd
sudo mv /tmp/argocd /usr/local/bin/argocd

kubectl create secret generic ai-webhook-secrets \
  --namespace owui-app \
  --from-literal=SMTP_USER="your@gmail.com" \
  --from-literal=SMTP_PASSWORD="your-gmail-app-password" \
  --from-literal=ALERT_EMAIL_TO="oncall@yourdomain.com"

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD password: $ARGOCD_PASSWORD"


# ── Helm repos ────────────────────────────────────────────────────────────
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
echo "Helm repos added"

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo "=== All dependencies installed ==="
echo "Run: source ~/.bashrc"
echo "Then verify: kubectl get nodes"
