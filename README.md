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
| Streaming | [Strimzi](https://strimzi.io/) (Kafka KRaft) + [Debezium](https://debezium.io/) (CDC) |
| Analytics | [ClickHouse](https://clickhouse.com/) via [Altinity Operator](https://github.com/Altinity/clickhouse-operator) |
| Orchestration | [Apache Airflow](https://airflow.apache.org/) |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- `kubectl`
- `kind` (bundled in `./bin/kind.exe`)
- `helm` (bundled in `./bin/helm.exe`)

## Quick Start

### 1. Create the Kind Cluster

```bash
./bin/kind.exe create cluster --config kind-config.yaml --name data-engineering-challenge
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
./bin/kind.exe load docker-image my-final-connect:1.1 --name data-engineering-challenge
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

## Verification

```bash
# All pods running
kubectl get pods -n kafka
kubectl get pods -n database

# Both CDC connectors READY=True
kubectl get kafkaconnector -n kafka

# CDC topics exist with data
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.users --from-beginning --max-messages 4 --timeout-ms 10000
```

## Repository Structure

```
.
├── infrastructure/
│   ├── Dockerfile.final          # Hybrid Connect image (Strimzi base + Debezium plugins)
│   ├── kraft-cluster.yaml        # Kafka cluster (KRaft, version 4.0.0)
│   ├── kafka-connect.yaml        # Kafka Connect CR
│   ├── postgres-connector.yaml   # Debezium PostgreSQL connector
│   ├── mongo-connector.yaml      # Debezium MongoDB connector
│   ├── postgres.yaml             # PostgreSQL 13 Deployment + Service
│   ├── mongo.yaml                # MongoDB 5.0 Deployment + Service (ReplicaSet)
│   ├── secrets.yaml              # DB credentials (Kubernetes Secrets)
│   └── clickhouse.yaml           # ClickHouse cluster (Altinity)
├── scripts/
│   ├── seed_postgres.sql         # Creates and seeds the users table
│   ├── seed_mongo.js             # Seeds the commerce.events collection
│   ├── create_bronze.sql         # ClickHouse Kafka engine tables
│   ├── create_silver.sql         # ClickHouse silver layer tables + MVs
│   └── create_tables.sql         # Combined ClickHouse schema
├── dags/                         # Airflow DAGs
├── docs/
│   └── phase3-cdc-pipeline.md   # Phase 3 deep-dive: architecture, issues, fixes
├── kind-config.yaml
└── README.md
```

## Documentation

- [Phase 3 — CDC Pipeline](docs/phase3-cdc-pipeline.md): Architecture decisions, deployment steps, and every issue encountered with root cause analysis and fixes.

## Status

| Phase | Description | Status |
|---|---|---|
| 1 | Environment setup (Kind, Strimzi, databases) | Done |
| 2 | Kafka cluster (KRaft mode) | Done |
| 3 | CDC pipeline (Kafka Connect + Debezium) | Done |
| 4 | ClickHouse ingestion + Airflow DAG | In Progress |
