# Barakah Data Engineering Challenge

## Project Overview

A production-grade CDC data pipeline running on local Kubernetes (Kind). Changes from PostgreSQL and MongoDB are captured in real-time by Debezium and streamed into Kafka, then ingested into ClickHouse for analytics and aggregated daily by Airflow.

**Pipeline Architecture**:

```
PostgreSQL (users)  ──┐                                                    ┌─────────────────────┐
                      ├── Debezium/Kafka Connect ──► Kafka ──► ClickHouse ─┤  Airflow (dbt)      │
MongoDB (events)    ──┘                                         (Silver)   │  BashOperator       │
                                                                           │  dbt run → dbt test │
                                                                           └─────────┬───────────┘
                                                                                     ▼
                                                                              gold_user_activity
                                                                              (Gold Layer)
```

## Tech Stack

| Layer | Technology |
|---|---|
| Platform | [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker) |
| Streaming | [Strimzi](https://strimzi.io/) (Kafka 4.0.0, KRaft) + [Debezium](https://debezium.io/) 2.7.0 (CDC) |
| Analytics | [ClickHouse](https://clickhouse.com/) 24.8 via [Altinity Operator](https://github.com/Altinity/clickhouse-operator) |
| Transformation | [dbt](https://www.getdbt.com/) 1.11 + [dbt-clickhouse](https://github.com/ClickHouse/dbt-clickhouse) adapter |
| Orchestration | [Apache Airflow](https://airflow.apache.org/) 3.0.2 (custom image with dbt baked in) |
| Observability | [Grafana](https://grafana.com/) with native ClickHouse plugin |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- `kubectl`
- `kind` (or use the bundled `./bin/kind.exe`)
- `helm` (or use the bundled `./bin/helm.exe`)

## Quick Start

### 1. Create the Kind Cluster

```bash
kind create cluster --config infrastructure/kind-config.yaml --name data-engineering-challenge
```

### 2. Install Strimzi Operator

```bash
kubectl create namespace kafka
kubectl apply -f https://strimzi.io/install/latest?namespace=kafka -n kafka
kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=120s
```

### 3. Deploy Kafka Cluster

```bash
kubectl apply -f infrastructure/kraft-cluster.yaml
kubectl wait kafka/my-cluster -n kafka --for=condition=Ready --timeout=300s
```

### 4. Build and Load the Connect Image

```bash
docker build -f infrastructure/Dockerfile.final -t my-final-connect:1.1 .
kind load docker-image my-final-connect:1.1 --name data-engineering-challenge
```

### 5. Deploy Databases and Kafka Connect

```bash
kubectl create namespace database
kubectl apply -f infrastructure/secrets.yaml
kubectl apply -f infrastructure/postgres.yaml
kubectl apply -f infrastructure/mongo.yaml
kubectl apply -f infrastructure/kafka-connect.yaml
```

Wait for Connect to be ready, then deploy connectors:

```bash
kubectl wait kafkaconnect/my-connect-cluster -n kafka --for=condition=Ready --timeout=600s
kubectl apply -f infrastructure/postgres-connector.yaml
kubectl apply -f infrastructure/mongo-connector.yaml
```

### 6. Initialize MongoDB and Seed Databases

```bash
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')

# PostgreSQL: seed users table
kubectl exec -n database $POSTGRES_POD -- psql -U postgres < scripts/seed_postgres.sql

# MongoDB: initialize replica set, create root user, seed events
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "rs.initiate({_id:'rs0',members:[{_id:0,host:'mongo-mongodb.database.svc.cluster.local:27017'}]})"
sleep 5
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "db.getSiblingDB('admin').createUser({user:'root',pwd:'password123',roles:[{role:'root',db:'admin'}]})"
kubectl exec -n database $MONGO_POD -- \
  mongosh "mongodb://root:password123@localhost:27017/?authSource=admin" \
  --file scripts/seed_mongo.js
```

### 7. Deploy ClickHouse

```bash
kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-bundle.yaml
kubectl apply -f infrastructure/clickhouse.yaml
kubectl wait pod -n database -l clickhouse.altinity.com/chi=chi-clickhouse --for=condition=Ready --timeout=120s
```

Create the schema:

```bash
kubectl exec -i -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" --multiquery < scripts/create_tables.sql
kubectl exec -i -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" --multiquery < scripts/create_gold.sql
```

### 8. Build Custom Airflow Image and Deploy

```bash
# Build Airflow image with dbt baked in
docker build -f infrastructure/Dockerfile.airflow-dbt -t airflow-dbt:1.0 .
kind load docker-image airflow-dbt:1.0 --name data-engineering-challenge

# Deploy Airflow
kubectl create namespace airflow
kubectl create configmap airflow-dags -n airflow --from-file=dags/gold_user_activity.py
helm repo add apache-airflow https://airflow.apache.org && helm repo update apache-airflow
helm install airflow apache-airflow/airflow \
  --namespace airflow \
  --values infrastructure/airflow-values.yaml \
  --timeout 10m
```

### 9. Deploy Grafana Dashboard

```bash
kubectl create namespace monitoring
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana
kubectl apply -f infrastructure/grafana-dashboard-configmap.yaml
helm install grafana grafana/grafana \
  --namespace monitoring \
  --values infrastructure/grafana-values.yaml \
  --timeout 5m
kubectl wait pod -n monitoring -l app.kubernetes.io/name=grafana --for=condition=Ready --timeout=120s

# Access at http://localhost:3000 (admin / admin)
kubectl port-forward svc/grafana 3000:3000 -n monitoring
```

## Verification

```bash
# All pods running
kubectl get pods -n kafka
kubectl get pods -n database
kubectl get pods -n airflow
kubectl get pods -n monitoring

# Both CDC connectors READY=True
kubectl get kafkaconnector -n kafka

# CDC topics exist with data
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# ClickHouse silver tables have data
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT count() FROM users_silver; SELECT count() FROM events_silver;"

# Trigger dbt via Airflow DAG (builds + tests the gold table)
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'airflow dags test gold_user_activity 2026-02-26 2>/dev/null | tail -5'

# Verify gold table has data
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT * FROM gold_user_activity FINAL ORDER BY date DESC, user_id LIMIT 10"

# Grafana dashboard
kubectl port-forward svc/grafana 3000:3000 -n monitoring
# Open http://localhost:3000/d/cdc-pipeline-v1/cdc-pipeline-overview
```

## Repository Structure

```
.
├── infrastructure/
│   ├── kind-config.yaml            # Kind cluster definition with port mappings
│   ├── Dockerfile.final            # Hybrid Connect image (Strimzi base + Debezium plugins)
│   ├── kraft-cluster.yaml          # Kafka cluster (KRaft, version 4.0.0)
│   ├── kafka-connect.yaml          # Kafka Connect CR
│   ├── postgres-connector.yaml     # Debezium PostgreSQL connector
│   ├── mongo-connector.yaml        # Debezium MongoDB connector
│   ├── postgres.yaml               # PostgreSQL 13 Deployment + Service
│   ├── mongo.yaml                  # MongoDB 5.0 Deployment + Service (ReplicaSet)
│   ├── secrets.yaml                # DB credentials (Kubernetes Secrets)
│   ├── clickhouse.yaml             # ClickHouse cluster (Altinity CHI)
│   ├── Dockerfile.airflow-dbt       # Custom Airflow image (Airflow 3.0.2 + dbt-core + dbt-clickhouse)
│   ├── airflow-values.yaml         # Airflow Helm chart values (custom image, dbt env vars)
│   ├── grafana-values.yaml         # Grafana Helm chart values
│   └── grafana-dashboard-configmap.yaml  # Grafana dashboard JSON (5 panels)
├── scripts/
│   ├── seed_postgres.sql           # Creates and seeds the users table
│   ├── seed_mongo.js               # Seeds the commerce.events collection
│   ├── create_tables.sql           # ClickHouse bronze + silver schema
│   ├── create_gold.sql             # ClickHouse gold table
│   ├── create_bronze.sql           # ClickHouse Kafka engine tables (standalone)
│   ├── create_silver.sql           # ClickHouse silver layer (standalone)
│   └── stress_test.sh              # Automated CDC stress test (8 progressive waves)
├── dbt/
│   ├── dbt_project.yml             # dbt project config
│   ├── profiles.yml                # ClickHouse connection profile
│   ├── models/
│   │   ├── staging/                # Ephemeral staging models (stg_users, stg_events)
│   │   └── gold/                   # Incremental gold model (gold_user_activity)
│   ├── macros/                     # Custom macros (reserved)
│   └── tests/                      # Custom data tests (reserved)
├── dags/
│   └── gold_user_activity.py       # Airflow DAG — dbt run + dbt test
├── docs/
│   ├── phase1-environment-setup.md # Phase 1: Kind, Strimzi, databases
│   ├── phase2-kafka-cluster.md     # Phase 2: Kafka KRaft + Connect image
│   ├── phase3-cdc-pipeline.md      # Phase 3: Debezium connectors + CDC
│   ├── phase4-gold-layer.md        # Phase 4: ClickHouse + Airflow
│   ├── phase5-stress-test-methodology.md  # Stress test design and rationale
│   ├── phase5-stress-test-results.md      # Stress test results and outcomes
│   ├── phase6-grafana-dashboard.md        # Grafana deployment and dashboard guide
│   ├── planned-enhancements-alerts-slos.md # Alert rules, SLOs, and production roadmap
│   ├── how-to-test-and-operate.md  # Operations manual and troubleshooting
│   ├── 01-Logical-Data-Flow-Architecture.png
│   ├── 02-Physical-Kubernetes-Architecture-Self-Hosted.png
│   └── 03-Physical-AWS-Cloud-Native-Architecture-Managed.png
├── logs/                           # Debug logs and diagnostic dumps
└── README.md
```

## Documentation

| Document | Description |
|---|---|
| [Phase 1 — Environment Setup](docs/phase1-environment-setup.md) | Kind cluster, Strimzi operator, database deployments, seed data |
| [Phase 2 — Kafka Cluster](docs/phase2-kafka-cluster.md) | Kafka KRaft, custom Connect image, internal topics, secret injection |
| [Phase 3 — CDC Pipeline](docs/phase3-cdc-pipeline.md) | Debezium connectors, CDC message format, connector troubleshooting |
| [Phase 4 — Gold Layer](docs/phase4-gold-layer.md) | ClickHouse schema, Airflow DAG, gold aggregation |
| [How to Test and Operate](docs/how-to-test-and-operate.md) | Full operations manual: health checks, testing, recovery, troubleshooting |
| [Phase 5 — Stress Test Methodology](docs/phase5-stress-test-methodology.md) | Test design, CPU budget analysis, 8 progressive wave rationale |
| [Phase 5 — Stress Test Results](docs/phase5-stress-test-results.md) | Results: 25K rows at 4,166–6,250 rows/s with sub-linear latency |
| [Phase 6 — Grafana Dashboard](docs/phase6-grafana-dashboard.md) | Live observability dashboard with ClickHouse datasource |
| [Planned Enhancements](docs/planned-enhancements-alerts-slos.md) | Alert rules, SLO definitions, and production roadmap |

## Status

| Phase | Description | Status |
|---|---|---|
| 1 | Environment setup (Kind, Strimzi, databases) | Done |
| 2 | Kafka cluster (KRaft mode) + Connect image | Done |
| 3 | CDC pipeline (Kafka Connect + Debezium) | Done |
| 4 | ClickHouse ingestion + Airflow gold DAG | Done |
| 5 | Stress testing (methodology + automated script) | Done |
| 6 | Grafana observability dashboard | Done |

## dbt Transformation Layer

dbt manages the silver → gold transformation with clear layer boundaries:

| Layer | Materialization | Engine | What it does |
|---|---|---|---|
| `stg_users` | Ephemeral (CTE) | — | Deduplicates users via `FINAL`, filters soft-deletes |
| `stg_events` | Ephemeral (CTE) | — | Passes through event facts |
| `gold_user_activity` | Incremental (append) | ReplacingMergeTree | Daily per-user aggregation |

**Orchestration**: dbt is baked into the Airflow image (`airflow-dbt:1.0`) and triggered by the `gold_user_activity` DAG:

```
BashOperator(dbt_run)  →  BashOperator(dbt_test)
   dbt run --select         dbt test --select
   gold_user_activity       gold_user_activity
```

**Run via Airflow** (inside the cluster):
```bash
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'airflow dags test gold_user_activity 2026-02-26 2>/dev/null'
```

**Run locally** (for development — requires `kubectl port-forward` to ClickHouse on `localhost:8123`):
```bash
cd dbt
dbt debug          # verify connection
dbt run            # build gold table
dbt test           # run not_null assertions
```

**Custom Airflow image** ([Dockerfile.airflow-dbt](infrastructure/Dockerfile.airflow-dbt)):
- Base: `apache/airflow:3.0.2`
- Adds: `dbt-core==1.11.6`, `dbt-clickhouse==1.10.0`
- Copies `dbt/` project into `/opt/airflow/dbt/`
- Env vars (`DBT_CH_HOST`, `DBT_CH_USER`, `DBT_CH_PASSWORD`) set via Helm values for in-cluster ClickHouse DNS

**Design decisions**:
- **Ephemeral staging**: no intermediate tables — staging models compile as CTEs into the gold query
- **Append strategy**: new rows inserted with `_updated_at = now()`; `FINAL` deduplicates on read — matches ReplacingMergeTree semantics
- **No `unique` tests**: ClickHouse only deduplicates on merge/FINAL, so uniqueness tests would produce false failures
- **Production path**: replace BashOperator with KubernetesPodOperator running a dedicated dbt Docker image — isolates dbt dependencies from the Airflow runtime

## Known Gaps & Next Steps

See [Planned Enhancements](docs/planned-enhancements-alerts-slos.md) — covers Grafana alert rules, SLO definitions, and Kafka lag monitoring. Deliberately deferred: SLO 2 requires Prometheus deployment; cost/benefit doesn't justify added infrastructure complexity on a single-node Kind cluster. On managed Kafka (AWS MSK), consumer lag is a built-in CloudWatch metric — no exporter needed.
