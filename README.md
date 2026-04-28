# 🚀 KubeNet — WordPress HA en Kubernetes

[![CI](https://github.com/DaniOrtegon/KubeNet/actions/workflows/ci.yml/badge.svg)](https://github.com/DaniOrtegon/KubeNet/actions/workflows/ci.yml)
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-Minikube-326CE5?logo=kubernetes)](https://daniortegon.github.io/KubeNet/)
[![Stack](https://img.shields.io/badge/Stack-WordPress%20%7C%20MariaDB%20%7C%20Redis%20%7C%20KEDA-informational)](https://github.com/DaniOrtegon/KubeNet#-stack-tecnológico)

> Infraestructura cloud-native completa sobre Minikube: alta disponibilidad, escalado por tráfico real, observabilidad end-to-end y seguridad en profundidad. Entorno de producción simulado, no una demo básica.

🔗 **Diagrama interactivo de la arquitectura**: [daniortegon.github.io/KubeNet](https://daniortegon.github.io/KubeNet/)

---

## 📑 Índice

1. [Descripción](#-descripción)
2. [Objetivo del proyecto](#-objetivo-del-proyecto)
3. [Despliegue rápido](#-despliegue-rápido)
4. [Stack tecnológico](#-stack-tecnológico)
5. [Arquitectura](#-arquitectura)
6. [Alta disponibilidad](#-alta-disponibilidad)
7. [Escalado automático (KEDA)](#-escalado-automático-keda)
8. [Seguridad](#-seguridad)
9. [Observabilidad](#-observabilidad)
10. [Backup y recuperación](#-backup-y-recuperación)
11. [CI Pipeline](#-ci-pipeline)
12. [Accesos y testing](#-accesos-y-testing)
13. [Estructura del proyecto](#-estructura-del-proyecto)
14. [Decisiones de diseño](#-decisiones-de-diseño)
15. [Limitaciones conocidas](#-limitaciones-conocidas)
16. [Posibles mejoras para Producción Real](#-posibles-mejoras-para-producción-real)
17. [Valor del proyecto](#-valor-del-proyecto)
18. [Comandos útiles](#-comandos-útiles)

---

## 📋 Descripción

KubeNet es un despliegue de WordPress en alta disponibilidad sobre Kubernetes (Minikube) diseñado como **entorno de producción simulado**, con las mismas capas que encontrarías en una arquitectura cloud-native real.

Lo que lo diferencia de una demo estándar: escala por tráfico real (no solo CPU), implementa observabilidad completa con métricas + logs + trazas, gestiona secretos cifrados versionables, y automatiza backups con objetivos RPO/RTO definidos. Todo el despliegue es reproducible desde cero con tres comandos.

---

## 🎯 Objetivo del proyecto

El objetivo no es levantar WordPress. Es demostrar:

- **IaC real**: toda la infraestructura declarada en YAML versionado, sin pasos manuales
- **Automatización completa**: un solo script despliega el clúster entero de forma idempotente
- **Reproducibilidad**: cualquier persona puede clonar el repo y tener el entorno exacto en minutos
- **Mínima intervención manual**: las contraseñas se generan interactivamente una sola vez y nunca se versionan

---

## ⚡ Despliegue rápido

### Requisitos previos

**Hardware del host:**

| Recurso | Mínimo | Recomendado | Base del cálculo |
|---|---|---|---|
| RAM | 6 GB | 8 GB | 3.7 GB reposo + 540 Mi pico KEDA + margen OS |
| CPU | 4 cores | 4–6 cores | 3.2 cores requests declarados; 602m uso base real |
| Disco Libre | 40 GB | 50 GB | ~25 GB PVCs + ~12 GB imágenes Docker + backups |
| SO | Ubuntu 22.04 | Ubuntu 24.04 / Debian 12 | Entorno de desarrollo y pruebas del proyecto |

**Software previo al despliegue:**

| Herramienta | Versión mínima | Versión probada | Instalada por |
|---|---|---|---|
| Docker | 24.0 | 28.3.1 | Manual / `01-install.sh` |
| kubectl | 1.28 | 1.35.4 | `01-install.sh` |
| Minikube | 1.32 | 1.38.1 | `01-install.sh` |
| Helm | 3.10 | 3.20.2 | `01-install.sh` |
| git | 2.x | 2.x | Manual (prerequisito) |
| jq | 1.6 | 1.6 | `01-install.sh` |
| hey | cualquiera | — | `apt` — Opcional, solo para pruebas de carga |

```bash
# 1. Clonar el repositorio
git clone https://github.com/DaniOrtegon/KubeNet.git
cd KubeNet

# 2. Instalar dependencias (Docker, kubectl, Minikube, Helm)
./01-install.sh

# 3. Configurar contraseñas (se generan interactivamente, nunca se guardan en el repo)
./02-setup.sh

# 4. Desplegar el clúster completo (fases 00 a 09)
./03-deploy.sh

# 5. Iniciar el clúster (también tras apagados o reinicios)
./start_all.sh
```

Acceso tras el despliegue: **https://wp-k8s.local**

> ✔ `03-deploy.sh` es **idempotente**: puede ejecutarse múltiples veces sin romper el estado del clúster.
> El navegador mostrará un aviso de certificado self-signed — acepta la excepción.

**Opciones del pipeline de despliegue:**
```bash
./03-deploy.sh --from 4     # Reanudar desde una fase concreta
./03-deploy.sh --only 7     # Ejecutar solo la fase de observabilidad
./03-deploy.sh --cleanup    # Destrucción controlada del entorno
```

---

## 🧠 Stack tecnológico

| Capa | Tecnología |
|---|---|
| Orquestación | Kubernetes (Minikube) |
| Aplicación | WordPress |
| Base de datos | MariaDB (Primary + Replica) |
| Caché | Redis + Sentinel |
| Autoscaling | KEDA |
| Almacenamiento | MinIO (S3 compatible) |
| TLS | cert-manager |
| Backup | Velero |
| Métricas | Prometheus + Alertmanager |
| Visualización | Grafana |
| Logs | Loki + Promtail |
| Trazas | Jaeger + OpenTelemetry |
| Secrets | Sealed Secrets (kubeseal) |
| CI | kubeconform · Kind |

---

## 🏗️ Arquitectura

### Flujo de petición

```
Browser
  │
  ▼
Ingress NGINX (TLS terminado)
  │
  ▼
Service WordPress
  │
  ┌──────────────┴──────────────┐
  ▼                             ▼
Redis (caché de objetos)   MariaDB Primary (R/W)
                                │
                                ▼
                          MariaDB Replica (R + failover)
```

### Namespaces

| Namespace | Propósito |
|---|---|
| `wordpress` | Aplicación |
| `databases` | MariaDB + Redis |
| `monitoring` | Observabilidad |
| `security` | cert-manager + Sealed Secrets |
| `storage` | MinIO + backups |
| `velero` | Snapshots de clúster |

### Componentes y HA

| Componente | Tipo | Alta Disponibilidad |
|---|---|---|
| WordPress | Deployment | Sí (mín. 2 pods) |
| MariaDB | StatefulSet | Primary + Replica |
| Redis | StatefulSet | Sentinel failover |
| MinIO | Deployment | Persistente |
| Prometheus Stack | Stateful | Observabilidad |

---

## 🔁 Alta disponibilidad

**WordPress**
- Mínimo 2 réplicas activas + `PodDisruptionBudget`
- `readinessProbe` y `livenessProbe` en todos los pods
- Escalado automático hasta 7 réplicas via KEDA

**MariaDB**
- `mariadb-0` → Primary (R/W), `mariadb-1` → Replica (R + failover)
- Replicación binlog automática gestionada por Job de inicialización
- `Seconds_Behind_Master: 0` — sincronización en tiempo real verificada

**Redis + Sentinel**
- 1 master + 2 réplicas
- 3 instancias de Sentinel con quórum de 2 para failover automático sin split-brain

---

## 📈 Escalado automático (KEDA)

El autoscaling está gestionado por **KEDA** (Kubernetes Event-Driven Autoscaling) en lugar de HPA clásico.

| Parámetro | Valor |
|---|---|
| Mínimo de pods | 2 |
| Máximo de pods | 7 |
| Trigger | Prometheus — `nginx_ingress_controller_requests` |
| Umbral de escalado | 10 req/s por réplica |
| Tiempo de reacción | ~2 segundos |

**Por qué KEDA y no HPA:**
- Escala de forma **proactiva** ante picos de tráfico, antes de que ocurra la saturación
- Usa métricas reales de tráfico (req/s desde Prometheus), no solo CPU
- Soporta múltiples triggers y métricas externas

---

## 🔐 Seguridad

- **NetworkPolicies (19 reglas)**: modelo default-deny en todos los namespaces; solo tráfico explícitamente declarado permitido
- **Sealed Secrets**: secretos cifrados con clave asimétrica vinculada al clúster; versionables en Git sin exponer credenciales
- **TLS (cert-manager)**: CA interna gestionada, certificados auto-renovables, HTTPS forzado en todos los endpoints; `FORCE_SSL_ADMIN` y `FORCE_SSL_LOGIN` activos en WordPress
- **Pod Security Standards**: perfil `baseline` en todos los namespaces; `privileged` únicamente en Velero (requerido por drivers de snapshot)

> ⚠️ No se almacenan credenciales reales ni en texto plano en el repositorio.

---

## 📊 Observabilidad

| Herramienta | Propósito |
|---|---|
| Prometheus | Recolección de métricas mediante scraping |
| Alertmanager | Gestión y envío de alertas a Slack |
| Grafana | Dashboards unificados: métricas + logs + trazas |
| Loki + Promtail | Agregación centralizada de logs por namespace |
| Jaeger | Trazas distribuidas |
| OpenTelemetry | Instrumentación y telemetría |

**SLOs definidos:**

| Indicador | Objetivo | Cómo se mide |
|---|---|---|
| Disponibilidad | ≥ 99.5% | Uptime de pods via Prometheus |
| RTO (Recuperación) | ≤ 15 min | Tiempo de restauración con Velero |
| RPO (Punto de recuperación) | ≤ 24h | Frecuencia de backups en MinIO |
| Tiempo de escalado | ≤ 30s | Latencia de respuesta de KEDA |

Los dashboards personalizados de Grafana están incluidos en el repo para importación directa:
- `dashboards/prometheus_metrics_dashboard.json` — métricas del clúster
- `dashboards/loki_logs_dashboard.json` — logs centralizados

---

## 💾 Backup y recuperación

**Estrategia dual de backup:**

| Tipo | Herramienta | Frecuencia | Destino |
|---|---|---|---|
| Snapshot completo del clúster | Velero | Diario 01:00 | MinIO `velero-backups` |
| Dump lógico de base de datos | CronJob + mysqldump | Diario 02:00 | MinIO `wordpress-backups` |
| Backup de uploads WordPress | CronJob | Diario 03:00 | MinIO `wordpress-uploads` |

| Indicador | Valor |
|---|---|
| RPO (Recovery Point Objective) | 24h |
| RTO (Recovery Time Objective) | ~15 min |
| Retención de backups | 30 días |

---

## 🔄 CI Pipeline

Validación automática en cada push al repositorio:

| Herramienta | Qué valida |
|---|---|
| `kubeconform` | Validación de esquemas de manifiestos YAML contra esquemas oficiales de Kubernetes |
| Kind (clúster efímero) | Simulación de despliegue: creación de namespaces y recursos core |

El pipeline actúa como filtro de seguridad: impide que configuraciones erróneas lleguen al entorno y garantiza que el clúster es siempre reproducible.

---

## 🌐 Accesos y testing

| Servicio | URL |
|---|---|
| WordPress | https://wp-k8s.local |
| Grafana | https://grafana.monitoring.local |
| Prometheus | https://prometheus.monitoring.local |
| MinIO | http://minio.storage.local |
| Jaeger | kubectl port-forward -n monitoring svc/jaeger-query 16686:16686 |

> Requiere `minikube tunnel` activo. Las entradas en `/etc/hosts` se actualizan automáticamente con `./start_all.sh`.

**Verificación rápida post-despliegue:**

```bash
# Comprobar que todos los pods están Running
kubectl get pods -A

# Verificar que el ScaledObject de KEDA está activo
kubectl get scaledobject -n wordpress

# Comprobar certificados TLS
kubectl get certificates -A

# Verificar backups de Velero
velero backup get
```

---

## 📁 Estructura del proyecto

```
.
├── 01-install.sh                        # Instalación de dependencias
├── 02-setup.sh                          # Configuración inicial de contraseñas
├── 03-deploy.sh                         # Despliegue idempotente completo (fases 00-09)
├── start_all.sh                         # Orquestador de arranque y recuperación
├── runbook.md                           # Procedimientos operativos
│
└── k8s/
    ├── app/
    │   ├── wordpress.yaml               # Deployment + Service de WordPress
    │   └── keda-wordpress.yaml          # ScaledObject KEDA (min:2 max:7)
    │
    ├── core/
    │   ├── namespace.yaml               # Namespaces del proyecto
    │   ├── configmap.yaml               # ConfigMaps
    │   ├── network-policy.yaml          # 19 NetworkPolicies (default-deny)
    │   ├── pdb.yaml                     # PodDisruptionBudget
    │   └── resource-quota.yaml          # ResourceQuota y LimitRange
    │
    ├── data/
    │   ├── mariadb.yaml                 # MariaDB HA (primary + replica)
    │   ├── mariadb-replication-job.yaml # Job de configuración de replicación binlog
    │   └── redis.yaml                   # Redis HA + Sentinel (quórum 2)
    │
    ├── edge/
    │   ├── cert-manager.yaml            # ClusterIssuers + Certificados TLS
    │   └── ingress.yaml                 # Ingress NGINX con TLS
    │
    ├── observability/
    │   ├── prometheus.yaml              # Prometheus + Alertmanager (Slack)
    │   ├── grafana.yaml                 # Grafana con datasources integrados
    │   ├── loki.yaml                    # Loki + Promtail
    │   └── tracing.yaml                 # Jaeger + OTel Collector
    │
    ├── storage/
    │   ├── pvc.yaml                     # PersistentVolumeClaims
    │   ├── minio.yaml                   # MinIO S3 compatible
    │   ├── backup.yaml                  # CronJobs de backup
    │   └── velero.yaml                  # Velero + NetworkPolicy
    │
    └── dashboards/
        ├── prometheus_metrics_dashboard.json   # Dashboard de métricas Grafana
        └── loki_logs_dashboard.json            # Dashboard de logs Grafana
```

---

## ⚖️ Decisiones de diseño

| Decisión | Motivo |
|---|---|
| YAML plano (sin Helm) | Control total sobre cada manifiesto; sin abstracciones que oculten comportamiento |
| KEDA en lugar de HPA | Escalado por tráfico real (req/s), no solo CPU; proactivo en vez de reactivo |
| MinIO en lugar de S3 real | Almacenamiento S3 local sin dependencia cloud; entorno 100% reproducible con coste 0€ |
| Sealed Secrets | Secretos cifrados versionables sin necesidad de gestión cloud externa |
| Estrategia dual de backup | Velero protege la infraestructura completa; CronJob permite restauración granular solo de BD |
| Jaeger en modo all-in-one | Menor complejidad operativa para entorno local, suficiente para validar el pipeline de trazas |
| Minikube | Entorno completamente reproducible en cualquier máquina local con coste 0€ |
| setup.sh interactivo | Las contraseñas nunca se versionan; se generan en el momento del despliegue |

---

## 🚧 Limitaciones conocidas

- **Entorno local**: sin LoadBalancer externo ni DNS público; requiere `minikube tunnel` y `/etc/hosts`
- **Sin multi-nodo**: Minikube corre en un único nodo; la HA es lógica, no física
- **Trazas Jaeger**: WordPress requiere el plugin de OpenTelemetry para generar trazas reales de la aplicación; el pipeline OTel Collector → Jaeger está operativo y listo para recibirlas
- **SLO de disponibilidad**: el entorno de laboratorio impone ciclos de apagado forzoso que impiden calcular el uptime de forma lineal; la arquitectura cumple el objetivo en condiciones de ejecución continua
- **Sin GitOps**: ArgoCD/Flux están fuera del alcance actual del proyecto

---

## 📌 Posibles mejoras para Producción Real

- [ ] **Helm / Kustomize**: sustituir los manifiestos YAML estáticos por plantillas dinámicas para gestionar entornos (Dev, Staging, Prod) sin duplicar código
- [ ] **External Secrets Operator**: integrar la gestión de secretos con HashiCorp Vault, AWS Secrets Manager o Azure Key Vault
- [ ] **Multi-nodo + Cluster Autoscaler**: migrar de un nodo único a un clúster gestionado (EKS/GKE) con nodos en distintas zonas de disponibilidad
- [ ] **Pipeline CI/CD completo**: añadir CD con ArgoCD o Flux para despliegue automático en modelo GitOps tras cada merge
- [ ] **Service Mesh (Istio/Linkerd)**: mTLS entre servicios, observabilidad avanzada y despliegues tipo Canary o Blue-Green

---

## 🧠 Valor del proyecto

Este proyecto demuestra capacidad para:

- Diseñar arquitecturas cloud-native completas con criterio, no solo seguir tutoriales
- Operar Kubernetes de forma realista: probes, PDBs, NetworkPolicies, resource quotas
- Implementar observabilidad real: métricas + logs + trazas + alertas + SLOs
- Gestionar secretos de forma segura sin comprometer la reproducibilidad del repo
- Tomar decisiones técnicas razonadas y documentarlas (KEDA vs HPA, MinIO vs S3, estrategia dual de backup, etc.)
- Automatizar el ciclo completo de despliegue con scripts idempotentes y modulares

---

## 🧰 Comandos útiles

```bash
# Estado general del clúster
kubectl get pods -A

# Logs de WordPress en tiempo real
kubectl logs -n wordpress -l app=wordpress -f

# Ver ScaledObject de KEDA
kubectl get scaledobject -n wordpress

# Listar backups de Velero
velero backup get

# Verificar certificados TLS
kubectl get certificates -A

# Estado de la replicación MariaDB
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"$MARIADB_ROOT_PASS" -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Running|Behind'

# Prueba de carga para verificar escalado KEDA
hey -n 1000 -c 50 https://wp-k8s.local

# Limpiar el entorno completo
./03-deploy.sh --cleanup
```
