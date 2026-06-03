FROM python:3.11-slim

WORKDIR /app

ARG KUBECTL_VERSION=v1.30.2
ARG HELM_VERSION=v3.15.2

# Install kubectl and helm CLI
RUN apt-get update && apt-get install -y curl ca-certificates git && \
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/ && \
    curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | \
      tar -xz --strip-components=1 linux-amd64/helm && \
    mv helm /usr/local/bin/ && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install helm diff plugin
RUN helm plugin install https://github.com/databus23/helm-diff \
    --version v3.9.4

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
