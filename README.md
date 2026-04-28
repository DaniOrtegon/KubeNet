# 🚀 KubeNet — WordPress HA on Kubernetes

[![CI](https://github.com/DaniOrtegon/KubeNet/actions/workflows/ci.yml/badge.svg)](https://github.com/DaniOrtegon/KubeNet/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/DaniOrtegon/KubeNet/blob/main/LICENSE)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-Minikube-326CE5?logo=kubernetes)](https://daniortegon.github.io/KubeNet/)
[![Stack](https://img.shields.io/badge/Stack-WordPress%20%7C%20MariaDB%20%7C%20Redis%20%7C%20KEDA-informational)](https://github.com/DaniOrtegon/KubeNet#-tech-stack)

> Full cloud-native infrastructure on Minikube: high availability, real-traffic autoscaling, end-to-end observability and defense-in-depth security. A production-simulated environment — not a basic demo.

🔗 **Interactive architecture diagram**: [daniortegon.github.io/KubeNet](https://daniortegon.github.io/KubeNet/)

---

## 📑 Table of Contents

1. [Description](#-description)
2. [Project Goals](#-project-goals)
3. [Quick Start](#-quick-start)
4. [Tech Stack](#-tech-stack)
5. [Architecture](#-architecture)
6. [High Availability](#-high-availability)
7. [Autoscaling (KEDA)](#-autoscaling-keda)
8. [Security](#-security)
9. [Observability](#-observability)
10. [Backup & Recovery](#-backup--recovery)
11. [CI Pipeline](#-ci-pipeline)
12. [Access & Testing](#-access--testing)
13. [Project Structure](#-project-structure)
14. [Design Decisions](#-design-decisions)
15. [Known Limitations](#-known-limitations)
16. [Production Improvements](#-production-improvements)
17. [Project Value](#-project-value)
18. [Useful Commands](#-useful-commands)

---

## 📋 Description

KubeNet is a WordPress deployment in high availability on Kubernetes (Minikube), designed as a **production-simulated environment** with the same layers you'd find in a real cloud-native architecture.

What sets it apart from a standard demo: it scales based on real traffic (not just CPU), implements full observability with metrics + logs + traces, manages encrypted versionable secrets, and automates backups with defined RPO/RTO objectives. The entire deployment is reproducible from scratch with three commands.

---

## 🎯 Project Goals

The goal is not to run WordPress. It's to demonstrate:

- **Real IaC**: entire infrastructure declared in versioned YAML, no manual steps
- **Full automation**: a single script deploys the entire cluster idempotently
- **Reproducibility**: anyone can clone the repo and have the exact environment running in minutes
- **Minimal manual intervention**: passwords are generated interactively once and never versioned

---

## ⚡ Quick Start

### Prerequisites

**Host hardware:**

| Resource | Minimum | Recommended | Calculation basis |
|---|---|---|---|
| RAM | 6 GB | 8 GB | 3.7 GB idle + 540 Mi KEDA peak + OS margin |
| CPU | 4 cores | 4–6 cores | 3.2 cores declared requests; 602m real base usage |
| Free Disk | 40 GB | 50 GB | ~25 GB PVCs + ~12 GB Docker images + backups |
| OS | Ubuntu 22.04 | Ubuntu 24.04 / Debian 12 | Development and testing environment |

**Required software:**

| Tool | Min version | Tested version | Installed by |
|---|---|---|---|
| Docker | 24.0 | 28.3.1 | Manual / `01-install.sh` |
| kubectl | 1.28 | 1.35.4 | `01-install.sh` |
| Minikube | 1.32 | 1.38.1 | `01-install.sh` |
| Helm | 3.10 | 3.20.2 | `01-install.sh` |
| git | 2.x | 2.x | Manual (prerequisite) |
| jq | 1.6 | 1.6 | `01-install.sh` |
| hey | any | — | `apt` — Optional, load testing only |

```bash
# 1. Clone the repository
git clone https://github.com/DaniOrtegon/KubeNet.git
cd KubeNet

# 2. Install dependencies (Docker, kubectl, Minikube, Helm)
./01-install.sh

# 3. Configure passwords (generated interactively, never stored in the repo)
./02-setup.sh

# 4. Deploy the full cluster (phases 00 to 09)
./03-deploy.sh

# 5. Start the cluster (also after shutdowns or reboots)
./start_all.sh
```

Access after deployment: **https://wp-k8s.local**

> ✔ `03-deploy.sh` is **idempotent**: it can be run multiple times without breaking the cluster state.
> Your browser will show a self-signed certificate warning — accept the exception.

**Pipeline options:**
```bash
./03-deploy.sh --from 4     # Resume from a specific phase
./03-deploy.sh --only 7     # Run only the observability phase
./03-deploy.sh --cleanup    # Controlled environment teardown
```

---

## 🧠 Tech Stack

| Layer | Technology |
|---|---|
| Orchestration | Kubernetes (Minikube) |
| Application | WordPress |
| Database | MariaDB (Primary + Replica) |
| Cache | Redis + Sentinel |
| Autoscaling | KEDA |
| Storage | MinIO (S3 compatible) |
| TLS | cert-manager |
| Backup | Velero |
| Metrics | Prometheus + Alertmanager |
| Visualization | Grafana |
| Logs | Loki + Promtail |
| Traces | Jaeger + OpenTelemetry |
| Secrets | Sealed Secrets (kubeseal) |
| CI | kubeconform · Kind |

---

## 🏗️ Architecture

### Request flow

```
Browser
  │
  ▼
Ingress NGINX (TLS termination)
  │
  ▼
WordPress Service
  │
  ┌──────────────┴──────────────┐
  ▼                             ▼
Redis (object cache)       MariaDB Primary (R/W)
                                │
                                ▼
                          MariaDB Replica (R + failover)
```

### Namespaces

| Namespace | Purpose |
|---|---|
| `wordpress` | Application |
| `databases` | MariaDB + Redis |
| `monitoring` | Observability |
| `security` | cert-manager + Sealed Secrets |
| `storage` | MinIO + backups |
| `velero` | Cluster snapshots |

### Components & HA

| Component | Type | High Availability |
|---|---|---|
| WordPress | Deployment | Yes (min. 2 pods) |
| MariaDB | StatefulSet | Primary + Replica |
| Redis | StatefulSet | Sentinel failover |
| MinIO | Deployment | Persistent |
| Prometheus Stack | Stateful | Observability |

---

## 🔁 High Availability

**WordPress**
- Minimum 2 active replicas + `PodDisruptionBudget`
- `readinessProbe` and `livenessProbe` on all pods
- Automatic scaling up to 7 replicas via KEDA

**MariaDB**
- `mariadb-0` → Primary (R/W), `mariadb-1` → Replica (R + failover)
- Automatic binlog replication managed by an init Job
- `Seconds_Behind_Master: 0` — real-time synchronization verified

**Redis + Sentinel**
- 1 master + 2 replicas
- 3 Sentinel instances with quorum of 2 for automatic failover without split-brain

---

## 📈 Autoscaling (KEDA)

Autoscaling is managed by **KEDA** (Kubernetes Event-Driven Autoscaling) instead of the classic HPA.

| Parameter | Value |
|---|---|
| Minimum pods | 2 |
| Maximum pods | 7 |
| Trigger | Prometheus — `nginx_ingress_controller_requests` |
| Scaling threshold | 10 req/s per replica |
| Reaction time | ~2 seconds |

**Why KEDA instead of HPA:**
- Scales **proactively** on traffic spikes, before saturation occurs
- Uses real traffic metrics (req/s from Prometheus), not just CPU
- Supports multiple triggers and external metrics

---

## 🔐 Security

- **NetworkPolicies (19 rules)**: default-deny model across all namespaces; only explicitly declared traffic is allowed
- **Sealed Secrets**: asymmetrically encrypted secrets tied to the cluster; versionable in Git without exposing credentials
- **TLS (cert-manager)**: managed internal CA, auto-renewable certificates, HTTPS enforced on all endpoints; `FORCE_SSL_ADMIN` and `FORCE_SSL_LOGIN` active in WordPress
- **Pod Security Standards**: `baseline` profile on all namespaces; `privileged` only for Velero (required by snapshot drivers)

> ⚠️ No real credentials or plaintext secrets are stored in this repository.

---

## 📊 Observability

| Tool | Purpose |
|---|---|
| Prometheus | Metrics collection via scraping |
| Alertmanager | Alert management and Slack notifications |
| Grafana | Unified dashboards: metrics + logs + traces |
| Loki + Promtail | Centralized log aggregation per namespace |
| Jaeger | Distributed tracing |
| OpenTelemetry | Instrumentation and telemetry |

**Defined SLOs:**

| Indicator | Target | How it's measured |
|---|---|---|
| Availability | ≥ 99.5% | Pod uptime via Prometheus |
| RTO (Recovery) | ≤ 15 min | Velero restore time |
| RPO (Recovery Point) | ≤ 24h | Backup frequency in MinIO |
| Scaling time | ≤ 30s | KEDA response latency |

Custom Grafana dashboards are included in the repo for direct import:
- `dashboards/prometheus_metrics_dashboard.json` — cluster metrics
- `dashboards/loki_logs_dashboard.json` — centralized logs

---

## 💾 Backup & Recovery

**Dual backup strategy:**

| Type | Tool | Frequency | Destination |
|---|---|---|---|
| Full cluster snapshot | Velero | Daily 01:00 | MinIO `velero-backups` |
| Logical database dump | CronJob + mysqldump | Daily 02:00 | MinIO `wordpress-backups` |
| WordPress uploads backup | CronJob | Daily 03:00 | MinIO `wordpress-uploads` |

| Indicator | Value |
|---|---|
| RPO (Recovery Point Objective) | 24h |
| RTO (Recovery Time Objective) | ~15 min |
| Backup retention | 30 days |

---

## 🔄 CI Pipeline

Automatic validation on every push to the repository:

| Tool | What it validates |
|---|---|
| `kubeconform` | YAML manifest schema validation against official Kubernetes schemas |
| Kind (ephemeral cluster) | Deployment simulation: namespace and core resource creation |

The pipeline acts as a safety gate: it prevents broken configurations from reaching the environment and guarantees the cluster is always reproducible.

---

## 🌐 Access & Testing

| Service | URL |
|---|---|
| WordPress | https://wp-k8s.local |
| Grafana | https://grafana.monitoring.local |
| Prometheus | https://prometheus.monitoring.local |
| MinIO | http://minio.storage.local |
| Jaeger | kubectl port-forward -n monitoring svc/jaeger-query 16686:16686 |

> Requires `minikube tunnel` active. `/etc/hosts` entries are updated automatically by `./start_all.sh`.

**Quick post-deployment check:**

```bash
# Check all pods are Running
kubectl get pods -A

# Verify KEDA ScaledObject is active
kubectl get scaledobject -n wordpress

# Check TLS certificates
kubectl get certificates -A

# List Velero backups
velero backup get
```

---

## 📁 Project Structure

```
.
├── 01-install.sh                        # Dependency installation
├── 02-setup.sh                          # Initial password setup
├── 03-deploy.sh                         # Idempotent full deployment (phases 00-09)
├── start_all.sh                         # Startup and recovery orchestrator
├── runbook.md                           # Operational procedures
│
└── k8s/
    ├── app/
    │   ├── wordpress.yaml               # WordPress Deployment + Service
    │   └── keda-wordpress.yaml          # KEDA ScaledObject (min:2 max:7)
    │
    ├── core/
    │   ├── namespace.yaml               # Project namespaces
    │   ├── configmap.yaml               # ConfigMaps
    │   ├── network-policy.yaml          # 19 NetworkPolicies (default-deny)
    │   ├── pdb.yaml                     # PodDisruptionBudget
    │   └── resource-quota.yaml          # ResourceQuota and LimitRange
    │
    ├── data/
    │   ├── mariadb.yaml                 # MariaDB HA (primary + replica)
    │   ├── mariadb-replication-job.yaml # Binlog replication init Job
    │   └── redis.yaml                   # Redis HA + Sentinel (quorum 2)
    │
    ├── edge/
    │   ├── cert-manager.yaml            # ClusterIssuers + TLS Certificates
    │   └── ingress.yaml                 # NGINX Ingress with TLS
    │
    ├── observability/
    │   ├── prometheus.yaml              # Prometheus + Alertmanager (Slack)
    │   ├── grafana.yaml                 # Grafana with integrated datasources
    │   ├── loki.yaml                    # Loki + Promtail
    │   └── tracing.yaml                 # Jaeger + OTel Collector
    │
    ├── storage/
    │   ├── pvc.yaml                     # PersistentVolumeClaims
    │   ├── minio.yaml                   # MinIO S3 compatible
    │   ├── backup.yaml                  # Backup CronJobs
    │   └── velero.yaml                  # Velero + NetworkPolicy
    │
    └── dashboards/
        ├── prometheus_metrics_dashboard.json   # Grafana metrics dashboard
        └── loki_logs_dashboard.json            # Grafana logs dashboard
```

---

## ⚖️ Design Decisions

| Decision | Reason |
|---|---|
| Plain YAML (no Helm) | Full control over every manifest; no abstractions hiding behavior |
| KEDA instead of HPA | Real traffic scaling (req/s); proactive rather than reactive |
| MinIO instead of real S3 | Local S3 storage with no cloud dependency; 100% reproducible at 0€ cost |
| Sealed Secrets | Encrypted versionable secrets without external cloud key management |
| Dual backup strategy | Velero protects the full infrastructure; CronJob enables granular DB-only restore |
| Jaeger all-in-one mode | Lower operational complexity for local environment; sufficient to validate the tracing pipeline |
| Minikube | Fully reproducible environment on any local machine at 0€ cost |
| Interactive setup.sh | Passwords are never versioned; generated at deployment time |

---

## 🚧 Known Limitations

- **Local environment**: no external LoadBalancer or public DNS; requires `minikube tunnel` and `/etc/hosts`
- **Single-node**: Minikube runs on a single node; HA is logical, not physical
- **Jaeger traces**: WordPress requires the OpenTelemetry plugin to generate real application traces; the OTel Collector → Jaeger pipeline is fully operational and ready to receive them
- **Availability SLO**: the lab environment enforces forced shutdown cycles that prevent linear uptime calculation; the architecture meets the target under continuous execution conditions
- **No GitOps**: ArgoCD/Flux are out of scope for this project

---

## 📌 Production Improvements

- [ ] **Helm / Kustomize**: replace static YAML manifests with dynamic templates to manage environments (Dev, Staging, Prod) without duplicating code
- [ ] **External Secrets Operator**: integrate secret management with HashiCorp Vault, AWS Secrets Manager or Azure Key Vault
- [ ] **Multi-node + Cluster Autoscaler**: migrate from a single node to a managed cluster (EKS/GKE) with nodes across multiple availability zones
- [ ] **Full CI/CD pipeline**: add CD with ArgoCD or Flux for automatic GitOps-based deployment on every merge
- [ ] **Service Mesh (Istio/Linkerd)**: mTLS between services, advanced observability and Canary/Blue-Green deployments

---

## 🧠 Project Value

This project demonstrates the ability to:

- Design complete cloud-native architectures with technical judgment, not just follow tutorials
- Operate Kubernetes realistically: probes, PDBs, NetworkPolicies, resource quotas
- Implement real observability: metrics + logs + traces + alerts + SLOs
- Manage secrets securely without compromising repo reproducibility
- Make reasoned technical decisions and document them (KEDA vs HPA, MinIO vs S3, dual backup strategy, etc.)
- Automate the full deployment lifecycle with idempotent, modular scripts

---

## 🧰 Useful Commands

```bash
# Overall cluster status
kubectl get pods -A

# WordPress logs in real time
kubectl logs -n wordpress -l app=wordpress -f

# Check KEDA ScaledObject
kubectl get scaledobject -n wordpress

# List Velero backups
velero backup get

# Check TLS certificates
kubectl get certificates -A

# MariaDB replication status
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"$MARIADB_ROOT_PASS" -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Running|Behind'

# Load test to verify KEDA autoscaling
hey -n 1000 -c 50 https://wp-k8s.local

# Full environment teardown
./03-deploy.sh --cleanup
```
