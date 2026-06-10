pipeline {
    agent any

    environment {
        ACR_NAME     = "openwebuiacrpersonal01"
        ACR_URL      = "openwebuiacrpersonal01.azurecr.io"
        WEBHOOK_REPO = "openwebuiacrpersonal01.azurecr.io/ai-webhook"
        IMAGE_TAG    = "${env.BUILD_NUMBER}"
    }

    stages {

        // ── Stage 1: Detect which branch and set cluster target ──────────
        stage('Set Environment') {
            steps {
                script {
                    echo "BRANCH_NAME=${env.BRANCH_NAME}"
                    if (env.GIT_BRANCH?.contains('prod')) {
                        env.DEPLOY_ENV      = 'production'
                        env.NAMESPACE_APP   = 'owui-app'
                        env.NAMESPACE_DATA  = 'owui-data'
                        env.KUBECONFIG_CRED = 'kubeconfig-production'
                        env.VALUES_FILE     = 'helm/values.yaml'
                        env.RELEASE_APP     = 'owui-app'
                        env.RELEASE_DATA    = 'owui-data'
                        env.EXTERNAL_IP_CRED = 'external-ip-production'
                        env.RESOURCE_GROUP = 'aks.prod'


                    } else if (env.GIT_BRANCH?.contains('staging')) {
                        env.DEPLOY_ENV      = 'staging'
                        env.NAMESPACE_APP   = 'owui-app'
                        env.NAMESPACE_DATA  = 'owui-data'
                        env.KUBECONFIG_CRED = 'kubeconfig-staging'
                        env.VALUES_FILE     = 'helm/values.yaml'
                        env.RELEASE_APP     = 'owui-app'
                        env.RELEASE_DATA    = 'owui-data'
                        env.EXTERNAL_IP_CRED = 'external-ip-staging'
                        env.RESOURCE_GROUP = 'aks.staging'

                    } else if (env.GIT_BRANCH?.contains('dev')) {
                        env.DEPLOY_ENV      = 'dev'
                        env.NAMESPACE_APP   = 'owui-app'
                        env.NAMESPACE_DATA  = 'owui-data'
                        env.KUBECONFIG_CRED = 'kubeconfig-dev'
                        env.VALUES_FILE     = 'helm/values.yaml'
                        env.RELEASE_APP     = 'owui-app'
                        env.RELEASE_DATA    = 'owui-data'
                        env.EXTERNAL_IP_CRED = 'external-ip-dev'
                        env.RESOURCE_GROUP = 'aks.dev'

                    } else {
                        error("Branch '${env.BRANCH_NAME}' is not configured for deployment.")
                    }
                    echo "Deploying to: ${env.DEPLOY_ENV}"
                }
            }
        }

        // ── Auth ────────────────────────────────────────────────────────────
        stage('Auth to Artifact Registry') {
            when { expression { env.DEPLOY_ENV != 'none' } }
            steps {
                sh '''
                    az aks get-credentials \
                        --resource-group ${env.RESOURCE_GROUP} \
                        --name ${env.CLUSTER_NAME} \
                   '''
            }
        }

        stage('Connect to Cluster') {
            when { expression { env.DEPLOY_ENV != 'none' } }
            steps {
                sh """
                    kubectl config use-context ${env.CLUSTER_NAME}
                    echo "Current Context:"
                    kubectl config current-context
                    kubectl get nodes
                """
            
                }
            }
        }

        // ── Stage 2: Validate Helm chart for both releases ───────────────
        stage('Validate Helm Chart') {
            steps {
                sh """
                    echo "=== Validating data release ==="
                    helm template ${env.RELEASE_DATA} ./helm \
                      --namespace ${env.NAMESPACE_DATA} \
                      --values ${env.VALUES_FILE} > /dev/null \
                      && echo "owui-data: YAML OK"
 
                    echo "=== Validating app release ==="
                    helm template ${env.RELEASE_APP} ./helm \
                      --namespace ${env.NAMESPACE_APP} \
                      --values ${env.VALUES_FILE} > /dev/null \
                      && echo "owui-app: YAML OK"
                """
            }
        }

        // ── Stage 2: Patch ingress-nginx externalIPs & disable Traefik ───
        stage('Patch Ingress') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    ),
                    string(
                        credentialsId: env.EXTERNAL_IP_CRED,
                        variable: 'EXTERNAL_IP'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG
 
                        echo "Patching ingress-nginx externalIPs for ${env.DEPLOY_ENV} (\$EXTERNAL_IP)"
                        kubectl patch svc ingress-nginx-controller \
                          -n ingress-nginx \
                          --type='merge' \
                          -p '{"spec":{"externalIPs":["'"$EXTERNAL_IP"'"]}}'
 
                    if kubectl get svc traefik -n kube-system >/dev/null 2>&1; then
                        echo "Demoting Traefik to ClusterIP"
                        kubectl patch svc traefik \
                        -n kube-system \
                        --type merge \
                        -p '{"spec":{"type":"ClusterIP"}}'
                    else
                    echo "Traefik service not found, skipping."
                    fi
 
                        echo "=== Verifying ingress-nginx service ==="
                        kubectl get svc -n ingress-nginx
                    """
                }
            }
        }

        // ── Stage 4: Build, Trivy scan & push AI webhook image to ACR ───
        stage('Build Webhook Image') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'acr-credentials',
                        usernameVariable: 'ACR_USER',
                        passwordVariable: 'ACR_PASS'
                    )
                ]) {
                    sh """
                        echo \$ACR_PASS | docker login ${ACR_URL} \
                          --username \$ACR_USER --password-stdin
 
                        docker build \
                          -t ${WEBHOOK_REPO}:${IMAGE_TAG} \
                          -t ${WEBHOOK_REPO}:${env.DEPLOY_ENV}-latest \
                          webhook/
 
                        echo "=== Trivy scan (report only — pipeline continues) ==="
                        trivy image \
                          --exit-code 0 \
                          --severity LOW,MEDIUM,HIGH,CRITICAL \
                          --format table \
                          --no-progress \
                          ${WEBHOOK_REPO}:${IMAGE_TAG} || true
 
                        docker push ${WEBHOOK_REPO}:${IMAGE_TAG}
                        docker push ${WEBHOOK_REPO}:${env.DEPLOY_ENV}-latest
 
                        echo "Pushed: ${WEBHOOK_REPO}:${IMAGE_TAG}"
                    """
                }
            }
        }

        // ── Stage 3: Deploy data layer ────────────────────────────────────
        stage('Deploy Data Layer') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    ),
                    string(
                        credentialsId: 'azure-storage-key',
                        variable: 'AZURE_STORAGE_KEY'
                    ),
                    string(
                        credentialsId: 'nvidia-api-key',
                        variable: 'NVIDIA_API_KEY'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG

                        kubectl create namespace ${env.NAMESPACE_DATA} \
                          --dry-run=client -o yaml | kubectl apply -f -

                        helm upgrade --install ${env.RELEASE_DATA} ./helm \
                          --namespace ${env.NAMESPACE_DATA} \
                          --values ${env.VALUES_FILE} \
                          --set azure.storageKey="\$AZURE_STORAGE_KEY" \
                          --set gateway.nvidiaApiKey="\$NVIDIA_API_KEY" \
                          --set gateway.enabled=false \
                          --set api.replicaCount=0 \
                          --set api.hpa.enabled=false \
                          --set api.ingress.enabled=false \
                          --set vllm.enabled=false \
                          --set ollama.enabled=false \
                          --set networkPolicies.enabled=false \
                          --set "minio.image.tag=RELEASE.2025-04-22T22-12-26Z" \
                          --wait --timeout=10m

                        kubectl get pods -n ${env.NAMESPACE_DATA}
                    """
                }
            }
        }

        // ── Stage 7: Verify data layer health ────────────────────────────
        stage('Verify Data Layer') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG
 
                        echo "=== Postgres cluster status ==="
                        kubectl get cluster -n ${env.NAMESPACE_DATA}
 
                        echo "=== Redis Sentinel masters ==="
                        kubectl exec -n ${env.NAMESPACE_DATA} \
                          ${env.RELEASE_DATA}-redis-0 -c sentinel -- \
                          redis-cli -p 26379 sentinel masters \
                          | grep -E "name|flags|num-slaves"
 
                        echo "=== Qdrant health ==="
                        kubectl exec -n ${env.NAMESPACE_DATA} \
                          ${env.RELEASE_DATA}-qdrant-0 -- \
                          curl -sf http://localhost:6333/healthz \
                          && echo "Qdrant: OK"
 
                    """
                }
            }
        }

        // ── Stage 7: Get Postgres credentials from running cluster ────────
        stage('Get Postgres Credentials') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    )
                ]) {
                    script {
                        env.PG_USER = sh(
                            script: "kubectl get secret ${env.RELEASE_DATA}-postgres-app -n ${env.NAMESPACE_DATA} -o jsonpath='{.data.username}' | base64 -d",
                            returnStdout: true
                        ).trim()
                        env.PG_PASS = sh(
                            script: "kubectl get secret ${env.RELEASE_DATA}-postgres-app -n ${env.NAMESPACE_DATA} -o jsonpath='{.data.password}' | base64 -d",
                            returnStdout: true
                        ).trim()
                        env.PG_DB = sh(
                            script: "kubectl get secret ${env.RELEASE_DATA}-postgres-app -n ${env.NAMESPACE_DATA} -o jsonpath='{.data.dbname}' | base64 -d",
                            returnStdout: true
                        ).trim()
                    }
                }
            }
        }

        // ── Stage 5: Deploy app layer ─────────────────────────────────────
        stage('Deploy App Layer') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    ),
                    string(
                        credentialsId: 'azure-storage-key',
                        variable: 'AZURE_STORAGE_KEY'
                    ),
                    string(
                        credentialsId: 'nvidia-api-key',
                        variable: 'NVIDIA_API_KEY'
                    ),
                    string(
                        credentialsId: 'liteLLM-masterkey',
                        variable: 'MASTERKEY_LLM'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG

                        kubectl create namespace ${env.NAMESPACE_APP} \
                          --dry-run=client -o yaml | kubectl apply -f -

                        helm upgrade --install ${env.RELEASE_APP} ./helm \
                          --namespace ${env.NAMESPACE_APP} \
                          --values ${env.VALUES_FILE} \
                          --set azure.storageKey="\$AZURE_STORAGE_KEY" \
                          --set gateway.nvidiaApiKey="\$NVIDIA_API_KEY" \
                          --set gateway.masterkey="\$MASTERKRY_LLM" \
                          --set postgres.cnpg.enabled=false \
                          --set redis.enabled=false \
                          --set qdrant.enabled=false \
                          --set minio.enabled=false \
                          --set vllm.enabled=false \
                          --set ollama.enabled=false \
                          --set postgres.external.enabled=true \
                          --set "postgres.external.url=postgresql://${env.PG_USER}:${env.PG_PASS}@${env.RELEASE_DATA}-postgres-rw.${env.NAMESPACE_DATA}.svc.cluster.local:5432/${env.PG_DB}" \
                          --set redis.external.enabled=true \
                          --set "redis.external.url=redis://${env.RELEASE_DATA}-redis-sentinel.${env.NAMESPACE_DATA}.svc.cluster.local:26379/0?sentinel=mymaster" \
                          --set qdrant.external.enabled=true \
                          --set "qdrant.external.url=http://${env.RELEASE_DATA}-qdrant.${env.NAMESPACE_DATA}.svc.cluster.local:6333" \
                          --wait --timeout=10m

                        kubectl get pods -n ${env.NAMESPACE_APP}
                    """
                }
            }
        }

        // ── Stage 9: Deploy monitoring stack ─────────────────────────────
        stage('Deploy Monitoring Stack') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG
 
                        helm install kube-prometheus-stack \
                          prometheus-community/kube-prometheus-stack \
                          --namespace monitoring \
                          --values monitoring/kube-prometheus-values.yaml \
                          --wait
 
                        helm install otel-collector \
                          open-telemetry/opentelemetry-collector \
                          --namespace monitoring \
                          --values monitoring/otel-collector-values.yaml
 
                        bash ~/open-webui/monitoring/apply-monitoring.sh
 
                        kubectl get pods -n monitoring
                        kubectl get pods -n monitoring | grep otel
                        kubectl get servicemonitor -n monitoring
                        kubectl get prometheusrule -n monitoring
                    """
                }
            }
        }
         
        // ── Stage 11: Register ArgoCD apps & enable auto-sync ────────────
        stage('Register ArgoCD Apps') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG
 
                        # Ensure port-forward is still alive
                        kubectl port-forward svc/argocd-server -n argocd 8080:443 \
                          --address 0.0.0.0 &
                        sleep 3
 
                        argocd login localhost:8080 \
                          --username admin \
                          --password \$(kubectl get secret argocd-initial-admin-secret \
                            -n argocd -o jsonpath="{.data.password}" | base64 -d) \
                          --insecure

                        ARGOCD_TOKEN=\$(argocd account generate-token --account admin) 
 
                        # Adopt owui-data
                        argocd app create owui-data \
                          --repo https://github.com/Tushryadav/open-webui.git \
                          --path helm \
                          --dest-server https://kubernetes.default.svc \
                          --dest-namespace ${env.NAMESPACE_DATA} \
                          --revision ${env.BRANCH_NAME} \
                          --values values.yaml \
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
                          --dest-namespace ${env.NAMESPACE_APP} \
                          --revision ${env.BRANCH_NAME} \
                          --values values.yaml \
                          --helm-set postgres.cnpg.enabled=false \
                          --helm-set redis.enabled=false \
                          --helm-set qdrant.enabled=false \
                          --helm-set minio.enabled=false \
                          --helm-set vllm.enabled=false \
                          --helm-set ollama.enabled=false \
                          --helm-set postgres.external.enabled=true \
                          --helm-set "postgres.external.url=postgresql://${env.PG_USER}:${env.PG_PASS}@${env.RELEASE_DATA}-postgres-rw.${env.NAMESPACE_DATA}.svc.cluster.local:5432/${env.PG_DB}" \
                          --helm-set redis.external.enabled=true \
                          --helm-set "redis.external.url=redis://${env.RELEASE_DATA}-redis-sentinel.${env.NAMESPACE_DATA}.svc.cluster.local:26379/0?sentinel=mymaster" \
                          --helm-set qdrant.external.enabled=true \
                          --helm-set "qdrant.external.url=http://${env.RELEASE_DATA}-qdrant.${env.NAMESPACE_DATA}.svc.cluster.local:6333" \
                          --sync-policy none \
                          --upsert
 
                        argocd app list
 
                        # Enable auto-sync + self-heal on owui-app only
                        argocd app set owui-app \
                          --sync-policy automated \
                          --self-heal \
                          --auto-prune
                    """
                }
            }
        }

        // ── Stage 12: Deploy AI webhook with versioned ACR image ─────────
        stage('Deploy AI Webhook') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    ),
                    string(
                        credentialsId: 'nvidia-api-key',
                        variable: 'NVIDIA_API_KEY'
                    ),
                    string(
                        credentialsId: 'argocd-token',
                        variable: 'ARGOCD_TOKEN'
                    ),
                    usernamePassword(
                        credentialsId: 'smtp-credentials',
                        usernameVariable: 'SMTP_USER',
                        passwordVariable: 'SMTP_PASS'
                    ),
                    string(
                        credentialsId: 'alert-email-to',
                        variable: 'ALERT_EMAIL_TO'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG
 
                        # Patch webhook deployment with versioned ACR image
                        sed \
                          -e 's|image: ai-webhook:latest|image: ${WEBHOOK_REPO}:${IMAGE_TAG}|g' \
                          -e 's|imagePullPolicy: Never|imagePullPolicy: Always|g' \
                          selfheal/webhook-deployment.yaml \
                          > /tmp/webhook-patched.yaml
 
                        # Create/update secret
                        kubectl create secret generic ai-webhook-secrets \
                          --namespace ${env.NAMESPACE_APP} \
                          --from-literal=NVIDIA_API_KEY="\$NVIDIA_API_KEY" \
                          --from-literal=ARGOCD_TOKEN="\$ARGOCD_TOKEN" \
                          --from-literal=SMTP_USER="\$SMTP_USER" \
                          --from-literal=SMTP_PASSWORD="\$SMTP_PASS" \
                          --from-literal=ALERT_EMAIL_TO="\$ALERT_EMAIL_TO" \
                          --dry-run=client -o yaml | kubectl apply -f -
 
                        kubectl apply -f /tmp/webhook-patched.yaml
 
                        kubectl rollout status deploy/ai-webhook \
                          -n ${env.NAMESPACE_APP} --timeout=120s
 
                        echo "Webhook running with image: ${WEBHOOK_REPO}:${IMAGE_TAG}"
                    """
                }
            }
        }

        // ── Stage 13: Health check ────────────────────────────────────────
        stage('Health Check') {
            steps {
                withCredentials([
                    file(
                        credentialsId: env.KUBECONFIG_CRED,
                        variable: 'KUBECONFIG'
                    ),
                    string(
                        credentialsId: env.EXTERNAL_IP_CRED,
                        variable: 'EXTERNAL_IP'
                    )
                ]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG
 
                        echo "=== All namespace pods ==="
                        echo "--- owui-app ---"
                        kubectl get pods -n ${env.NAMESPACE_APP}
                        echo "--- owui-data ---"
                        kubectl get pods -n ${env.NAMESPACE_DATA}
                        echo "--- monitoring ---"
                        kubectl get pods -n monitoring
 
                        echo "=== HTTP health check ==="
                        curl -sf http://openwebui.\$EXTERNAL_IP.nip.io/health \
                          && echo "UI: OK"
 
                        echo "=== API startup log ==="
                        kubectl logs -n ${env.NAMESPACE_APP} \
                          deployment/${env.RELEASE_APP}-open-webui-production-api \
                          | grep "startup complete" || true
 
                        echo "=== LiteLLM gateway log ==="
                        kubectl logs -n ${env.NAMESPACE_APP} \
                          deployment/${env.RELEASE_APP}-inference-gateway \
                          | grep -i "litellm\\|started\\|proxy" || true
 
                        echo "=== Webhook health ==="
                        WEBHOOK_IP=\$(kubectl get svc ai-webhook \
                          -n ${env.NAMESPACE_APP} \
                          -o jsonpath='{.spec.clusterIP}')
                        kubectl exec -n ${env.NAMESPACE_APP} deploy/ai-webhook -- \
                          curl -sf http://\$WEBHOOK_IP:8000/healthz \
                          && echo "Webhook: OK"
 
                        echo "=== All good: ${env.DEPLOY_ENV} — build ${IMAGE_TAG} ==="
                    """
                }
            }
        }
    }
 
    post {
        success {
            echo "Pipeline SUCCESS — ${env.DEPLOY_ENV} — build ${IMAGE_TAG}"
        }
        failure {
            echo "Pipeline FAILED — ${env.DEPLOY_ENV} — check logs"
        }
    }
}
