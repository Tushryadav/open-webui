# Open WebUI — Production Kubernetes Helm Chart

> A production-grade, highly available deployment of [Open WebUI](https://github.com/open-webui/open-webui) on Kubernetes — with a full data layer, inference gateway, observability stack, and CI/CD pipeline built in from day one.

---

## The Problem

Most teams deploying AI chat platforms hit the same wall.

They start with a Docker Compose file. It works locally. Then they move it to a VM, expose a port, and call it production. A few weeks later:

- The app goes down and nobody knows why — no metrics, no alerts, no logs aggregated
- A bad deploy takes down the service and rollback is manual
- Sensitive employee or customer data is being sent to OpenAI because there was no time to evaluate alternatives
- The Postgres container and the app container share the same restart fate
- Redis is a single instance with no failover — sessions drop when it restarts

This chart exists to solve all of those before they happen.

---

## What This Solves

### Data Privacy
Enterprises in **banking, healthcare, and legal** cannot send internal documents, customer data, or employee conversations to a third-party API. This stack is fully self-hosted and air-gappable. NetworkPolicy blocks all unintended egress at the pod level — the data layer is unreachable from anything except the application layer.

### Vendor Lock-in
The LiteLLM gateway sits between the application and every model provider. Switching from NVIDIA NIM to Azure OpenAI, AWS Bedrock, or a locally hosted vLLM cluster is a four-line config change. The application never touches a provider API directly — it only talks to LiteLLM.

### Operational Blindness
Most self-hosted AI deployments have zero observability until something breaks in production. This stack ships with Prometheus Operator, Grafana, and AlertManager configured from day one. Open WebUI has an OpenTelemetry SDK built in — one environment variable turns on full HTTP metrics, active session tracking, and AI task queue depth. No custom instrumentation written.

### Fragile Deployments
A Jenkins pipeline with `--atomic` deployment, a post-deploy health check gate, and an automatic `helm rollback` stage means a bad release never reaches users for more than the duration of a readiness probe timeout. Three layers of recovery built into every deploy.

### Stateful Services Without Operators
Running Postgres as a plain StatefulSet on Kubernetes means manually handling failover, WAL archiving, replica promotion, and backups. The CloudNativePG operator handles all of it. Redis Sentinel runs as a sidecar on every Redis pod — primary failover is transparent to the application.

---

## Architecture

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │                          INTERNET                                   │
 └───────────────────────────────┬─────────────────────────────────────┘
                                 │ HTTPS :443 / HTTP :80
                                 ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │                    nginx Ingress Controller                         │
 │              (TLS termination, WebSocket upgrade,                   │
 │               3600s proxy timeout for AI streaming)                 │
 └───────────────────────────────┬─────────────────────────────────────┘
                                 │
                                 ▼
 ┌─────────────────────── owui-app namespace ──────────────────────────┐
 │                                                                     │
 │   ┌─────────────────────────────────────┐                           │
 │   │       Open WebUI API                │                           │
 │   │   Deployment — 3 pods (HPA → 10)    │                           │
 │   │   PodDisruptionBudget: min 2 alive  │                           │
 │   │   OTel SDK → Prometheus metrics     │                           │
 │   └──────────────┬──────────────────────┘                           │
 │                  │ http://inference-gateway:8000/v1                 │
 │                  ▼                                                  │
 │   ┌─────────────────────────────────────┐                           │
 │   │       LiteLLM Inference Gateway     │                           │
 │   │   Deployment — 2 pods               │                           │
 │   │   Routes per model config in        │                           │
 │   │   ConfigMap → NVIDIA NIM APIs       │                           │
 │   └──────────────┬──────────────────────┘                           │
 │                  │ HTTPS → integrate.api.nvidia.com/v1              │
 │                  ▼                                                  │
 │         ┌────────────────────────────────────────┐                  │
 │         │          NVIDIA NIM APIs               │                  │
 │         │  llama-3.1-70b / llama-3.1-8b          │                  │
 │         │  mistral-7b / gemma-2-27b              │                  │
 │         └────────────────────────────────────────┘                  │
 │                                                                     │
 └──────────────────────────┬──────────────────────────────────────────┘
                            │ NetworkPolicy: only owui-app → owui-data
                            ▼
 ┌─────────────────────── owui-data namespace ─────────────────────────┐
 │                                                                     │
 │  ┌──────────────────────┐   ┌──────────────────────────────────┐    │
 │  │  PostgreSQL (CNPG)   │   │  Redis Sentinel                  │    │
 │  │  3-instance cluster  │   │  3 pods                          │    │
 │  │  Auto WAL archiving  │   │  redis + sentinel sidecar        │    │
 │  │  Replica promotion   │   │  Session state, WebSocket coord  │    │
 │  │  PVC: 10Gi + 5Gi WAL │   │  PVC: 5Gi each                   │    │
 │  └──────────────────────┘   └──────────────────────────────────┘    │
 │                                                                     │
 │  ┌──────────────────────┐   ┌──────────────────────────────────┐    │
 │  │  Qdrant              │   │  Azure Blob Storage              │    │
 │  │  Vector DB for RAG   │   │  File uploads, PDFs, images      │    │
 │  │  Semantic search     │   │  Never touches cluster disk      │    │
 │  │  PVC: 10Gi           │   │  External — always available     │    │
 │  └──────────────────────┘   └──────────────────────────────────┘    │
 │                                                                     │
 └─────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────── monitoring namespace ────────────────────────┐
 │                                                                     │
 │  Prometheus ──────── scrapes via ServiceMonitors / PodMonitors ──►  │
 │  ├── Open WebUI API     (OTel → Collector → Prometheus)             │
 │  ├── LiteLLM Gateway    (/metrics on :8000)                         │
 │  ├── PostgreSQL         (CNPG PodMonitor)                           │
 │  ├── Redis              (redis-exporter sidecar → :9121)            │
 │  ├── Qdrant             (/metrics on :6333)                         │
 │  ├── nginx Ingress      (/metrics on :10254)                        │
 │  └── K8s cluster        (kube-state-metrics + node-exporter)        │
 │                                                                     │
 │  Grafana ──────────── dashboards + alerting UI                      │
 │  AlertManager ──────── routes alerts → email / Slack                │
 │  OTel Collector ─────── receives OTLP from app, exposes /metrics    │
 │                                                                     │
 └─────────────────────────────────────────────────────────────────────┘

 ┌───────────────────────  CI/CD (Jenkins) ────────────────────────────┐
 │                                                                     │
 │  GitHub Push                                                        │
 │      │                                                              │
 │      ▼                                                              │
 │  Stage 1: Build + Push → Google Artifact Registry                   │
 │      │                                                              │
 │      ▼                                                              │
 │  Stage 2: Helm Lint + Dry Run                                       │
 │      │                                                              │
 │      ▼                                                              │
 │  Stage 3: helm upgrade --atomic --namespace owui-app                │
 │      │         └── rolls back entire release if timeout             │
 │      ▼                                                              │
 │  Stage 4: Health Check → GET /health → {"status":true}              │
 │      │         └── if FAIL → Stage 5                                │
 │      ▼                                                              │
 │  Stage 5: helm rollback (automatic, no human needed)                │
 │                                                                     │
 └─────────────────────────────────────────────────────────────────────┘
```

---

## Stack

| Layer | Component | Why |
|---|---|---|
| Application | Open WebUI | Self-hosted AI chat, OTel built-in |
| Model Gateway | LiteLLM | Provider-agnostic model routing |
| Model APIs | NVIDIA NIM | Free-tier LLMs — Llama 3.1, Mistral, Gemma |
| Database | PostgreSQL via CNPG | Operator-managed HA, auto-failover |
| Cache / Sessions | Redis Sentinel | Transparent failover, WebSocket coordination |
| Vector DB | Qdrant | RAG over private documents |
| File Storage | Azure Blob Storage | Off-cluster, always available |
| Ingress | nginx Ingress Controller | TLS termination, WebSocket upgrade, streaming timeouts |
| Metrics | Prometheus Operator | ServiceMonitor-based auto-discovery |
| Dashboards | Grafana | Pre-loaded community dashboards |
| Alerting | AlertManager | Routes to email/Slack/PagerDuty |
| Tracing | OpenTelemetry Collector | Receives OTLP from app, feeds Prometheus |
| CI/CD | Jenkins | Build → Deploy → Health check → Auto rollback |
| Package Manager | Helm | Templated, values-driven, versioned releases |
| Container Runtime | K3s (Kubernetes) | Lightweight, production-capable single-node |

---

## Security Design

| Decision | What it prevents |
|---|---|
| All secrets via `secretKeyRef` | Credentials never appear in Git, logs, or pod specs |
| CNPG auto-generates Postgres password | No human ever knows or sets the DB password |
| NetworkPolicy: owui-data unreachable except from owui-app | Compromised inference pod cannot reach DB or cache |
| LiteLLM master key as the only outward credential | Open WebUI never holds real provider API keys |
| Azure Blob Storage for uploads | User files never touch cluster disk or pod filesystem |
| TLS via cert-manager + Let's Encrypt | All traffic encrypted in transit |

---

## Scalability Design

| Decision | What it enables |
|---|---|
| HPA on API pods (3 → 10) | Handles traffic spikes without manual intervention |
| PodDisruptionBudget (min 2 alive) | Node drains never take down the entire API layer |
| Stateless LiteLLM gateway | Scale horizontally, no session affinity needed |
| Redis Sentinel (3 nodes) | Primary failover in under 5 seconds, app unaware |
| CNPG 3-instance cluster | Replica promotion automatic, read replicas available |
| Per-pod PVCs on all StatefulSets | No shared volume contention, safe independent restarts |

---

## Observability Design

Open WebUI ships with an **OpenTelemetry SDK** — setting `ENABLE_OTEL_METRICS=True` enables:

- HTTP request rate and latency per endpoint
- Active WebSocket connections
- AI generation task queue depth
- Daily and real-time active user counts

All metrics flow: `App → OTel Collector → Prometheus → Grafana`

ServiceMonitors auto-discover targets as pods come and go. No static scrape configs. AlertManager fires on OOMKills, replication lag, PVC usage, HPA saturation, and Redis quorum loss.

---

## Why Not Just Use Docker Compose

| | Docker Compose | This Stack |
|---|---|---|
| Failover | Manual restart | Automatic (CNPG, Sentinel, K8s) |
| Scaling | Manual | HPA, automatic |
| Rolling deploys | Downtime | Zero-downtime with PDB |
| Bad deploy recovery | Manual rollback | Automatic via `--atomic` + Jenkins |
| Observability | Nothing | Full Prometheus + Grafana stack |
| Secrets | Plaintext in `.env` | K8s Secrets, never in Git |
| Network isolation | None | NetworkPolicy per namespace |

---

## Repository Structure

```
open-webui/
├── helm/
│   ├── Chart.yaml
│   ├── values.yaml                        ← defaults, no secrets
│   ├── values-production.yaml.example     ← template, copy and fill in
│   └── templates/
│       ├── api-deployment.yaml
│       ├── api-hpa.yaml
│       ├── api-ingress.yaml
│       ├── api-pdb.yaml
│       ├── api-service.yaml
│       ├── gateway-configmap.yaml
│       ├── gateway-deployment.yaml
│       ├── gateway-service.yaml
│       ├── networkpolicies.yaml
│       ├── postgres-cnpg.yaml
│       ├── redis-statefulset.yaml
│       ├── redis-service.yaml
│       ├── redis-configmap.yaml
│       ├── qdrant-statefulset.yaml
│       ├── qdrant-service.yaml
│       ├── minio-statefulset.yaml
│       ├── minio-service.yaml
│       ├── secrets.yaml
│       ├── servicemonitors.yaml
│       ├── vllm-deployment.yaml           ← disabled by default
│       ├── ollama-statefulset.yaml        ← disabled by default
│       └── ollama-service.yaml
├── monitoring/
│   ├── kube-prometheus-values.yaml
│   └── otel-collector-values.yaml
├── .gitignore
├── DEPLOYMENT.md
├── MONITORING.md
└── README.md
```

---

## Credits

| Project | Role in this stack |
|---|---|
| [Open WebUI](https://github.com/open-webui/open-webui) | Core application — self-hosted AI chat interface |
| [LiteLLM](https://github.com/BerriAI/litellm) | Inference gateway — unified API across all LLM providers |
| [CloudNativePG](https://cloudnative-pg.io) | Kubernetes operator for production-grade PostgreSQL |
| [NVIDIA NIM](https://build.nvidia.com) | Free-tier inference APIs — Llama 3.1, Mistral, Gemma |
| [Qdrant](https://qdrant.tech) | Vector database for RAG and semantic search |
| [Prometheus](https://prometheus.io) | Metrics collection and time-series storage |
| [Grafana](https://grafana.com) | Metrics visualization and alerting dashboards |
| [OpenTelemetry](https://opentelemetry.io) | Observability instrumentation standard |
| [cert-manager](https://cert-manager.io) | Automated TLS certificate management |
| [Helm](https://helm.sh) | Kubernetes package manager |
| [K3s](https://k3s.io) | Lightweight Kubernetes distribution |

---

> **Note:** Never commit `values-production.yaml` to Git. It contains secrets.
> Use `values-production.yaml.example` as the template and store real values in a secrets manager.
