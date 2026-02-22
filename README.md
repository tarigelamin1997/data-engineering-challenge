# Barakah Data Engineering Challenge

## Project Overview

A production-grade CDC data pipeline running on local Kubernetes (Kind). Changes from PostgreSQL and MongoDB are captured in real-time by Debezium and streamed into Kafka, then ingested into ClickHouse for analytics and aggregated daily by Airflow.

**Pipeline Architecture**:

```
PostgreSQL (users)  ──┐
                      ├── Debezium/Kafka Connect ──► Kafka ──► ClickHouse ──► Airflow
MongoDB (events)    ──┘                                         (Silver)       (Gold)
```

## Tech Stack

| Layer | Technology |
|---|---|
| Platform | [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker) |
| Streaming | [Strimzi](https://strimzi.io/) (Kafka 4.0.0, KRaft) + [Debezium](https://debezium.io/) 2.7.0 (CDC) |
| Analytics | [ClickHouse](https://clickhouse.com/) 24.8 via [Altinity Operator](https://github.com/Altinity/clickhouse-operator) |
| Orchestration | [Apache Airflow](https://airflow.apache.org/) 3.1.7 |
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

### 8. Deploy Airflow

```bash
kubectl create namespace airflow
kubectl create configmap airflow-dags -n airflow --from-file=dags/gold_user_activity.py
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

# Both CDC connectors READY=True
kubectl get kafkaconnector -n kafka

# CDC topics exist with data
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# ClickHouse silver tables have data
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT count() FROM users_silver; SELECT count() FROM events_silver;"

# Gold table (after DAG run)
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT * FROM gold_user_activity FINAL ORDER BY date DESC, user_id"

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
│   ├── airflow-values.yaml         # Airflow Helm chart values
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
├── dags/
│   └── gold_user_activity.py       # Airflow DAG — daily gold aggregation
├── docs/
│   ├── phase1-environment-setup.md # Phase 1: Kind, Strimzi, databases
│   ├── phase2-kafka-cluster.md     # Phase 2: Kafka KRaft + Connect image
│   ├── phase3-cdc-pipeline.md      # Phase 3: Debezium connectors + CDC
│   ├── phase4-gold-layer.md        # Phase 4: ClickHouse + Airflow
│   ├── phase5-stress-test-methodology.md  # Stress test design and rationale
│   ├── phase5-stress-test-results.md      # Stress test results and outcomes
│   ├── phase6-grafana-dashboard.md        # Grafana deployment and dashboard guide
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

## Status

| Phase | Description | Status |
|---|---|---|
| 1 | Environment setup (Kind, Strimzi, databases) | Done |
| 2 | Kafka cluster (KRaft mode) + Connect image | Done |
| 3 | CDC pipeline (Kafka Connect + Debezium) | Done |
| 4 | ClickHouse ingestion + Airflow gold DAG | Done |
| 5 | Stress testing (methodology + automated script) | Done |
| 6 | Grafana observability dashboard | Done |
