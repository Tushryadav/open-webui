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

# ── Jenkins ───────────────────────────────────────────────────────────────
sudo apt update
sudo apt install fontconfig openjdk-21-jre
java -version

sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins

sudo systemctl enable jenkins
sudo systemctl start jenkins

# ── Azure CLI ───────────────────────────────────────────────────────────────
curl -fsSL 'https://azurecliprod.blob.core.windows.net/$root/deb_install.sh' | sudo bash
az version
az login
az account show

# ── kubectl ───────────────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl && sudo mv kubectl /usr/local/bin/
    echo "kubectl installed"
else
    echo "kubectl already installed: $(kubectl version --client --short 2>/dev/null)"
fi

# ── Install kubelogin ───────────────────────────────────────────────────────────────
if ! command -v kubelogin &>/dev/null; then
    curl -LO https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-amd64.zip
    unzip -o kubelogin-linux-amd64.zip
    sudo mv bin/linux_amd64/kubelogin /usr/local/bin/
    sudo chmod +x /usr/local/bin/kubelogin
    rm -rf bin kubelogin-linux-amd64.zip
fi
kubelogin --version

# ── Get AKS Cluster Credentials ───────────────────────────────────────────────────────────────
declare -A AKS_CLUSTERS=(
    ["dev"]="rg-dev:aks-dev"
    ["staging"]="rg-staging:aks-staging"
    ["production"]="rg-production:aks-production"
)
 
mkdir -p ~/.kube
 
for ENV in dev staging production; do
    IFS=':' read -r RG CLUSTER <<< "${AKS_CLUSTERS[$ENV]}"
    KUBE_FILE="$HOME/.kube/config-${ENV}"
 
    echo "  Fetching kubeconfig: $CLUSTER ($RG) → $KUBE_FILE"
    az aks get-credentials \
        --resource-group "$RG" \
        --name "$CLUSTER" \
        --file "$KUBE_FILE" \
        --overwrite-existing
 
    # Convert kubeconfig to use kubelogin (required for AKS AAD auth)
    KUBECONFIG="$KUBE_FILE" kubelogin convert-kubeconfig -l azurecli
 
    echo "  $ENV kubeconfig ready: $KUBE_FILE"
done
 
# Give Jenkins access to all three kubeconfigs
sudo mkdir -p /var/lib/jenkins/.kube
for ENV in dev staging production; do
    sudo cp "$HOME/.kube/config-${ENV}" /var/lib/jenkins/.kube/config-${ENV}
done
sudo chown -R jenkins:jenkins /var/lib/jenkins/.kube
echo "Kubeconfigs copied for Jenkins"

# ── switch cluster ───────────────────────────────────────────────────────────────
kubectl config current-context
kubectl config use-context aks-prod

# ── Docker ───────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER 
    sudo usermod -aG docker jenkins  
    echo "Docker installed — re-login or run: newgrp docker"
else
    echo "Docker already installed: $(docker --version)"
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
  --create-namespace &

kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=cloudnative-pg \
  -n cnpg-system --timeout=120s
echo "CNPG operator ready"

# ── Trivy (used by Jenkins Build Webhook Image stage) ────────────────────
if ! command -v trivy &>/dev/null; then
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
      | sudo sh -s -- -b /usr/local/bin
    echo "Trivy installed"
fi

# ──cert-manager ──────────────────────────────────────────────────────────────────

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# ──nginx Ingress Controller ──────────────────────────────────────────────────────────────────
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.type=LoadBalancer &

kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=120s
echo "nginx ingress ready"


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

kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=180s
echo "ArgoCD ready"

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
echo "=== cnpg-system ===" && kubectl get pods -n cnpg-system -w
echo "=== cert-manager ===" && kubectl get pods -n cert-manager -w
echo "=== ingress-nginx ===" && kubectl get pods -n ingress-nginx -w
