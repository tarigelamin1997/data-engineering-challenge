# Phase 1: Environment Setup

## Objective

Provision a local Kubernetes development environment using Kind (Kubernetes in Docker), deploy the Strimzi Kafka operator, and deploy the source databases (PostgreSQL, MongoDB) that will feed the CDC pipeline.

---

## Components Deployed

| Component | Resource | Namespace | Details |
|---|---|---|---|
| Kind cluster | `data-engineering-challenge` | N/A | Single control-plane node, Kubernetes v1.30.0 |
| Strimzi Operator | Deployment | `kafka` | v0.50.0 — manages Kafka, KafkaConnect, KafkaConnector CRDs |
| PostgreSQL | Deployment + Service | `database` | `postgres:13`, WAL level set to `logical` for CDC |
| MongoDB | Deployment + Service | `database` | `mongo:5.0`, started with `--replSet rs0` for change streams |
| DB Credentials | Secrets | `kafka` | `postgres-credentials`, `mongo-credentials` |

---

## Architecture

```
Host Machine (Windows 11 + Docker Desktop)
  └── Kind Container (kindest/node:v1.30.0)
        ├── Namespace: kafka
        │     └── Strimzi Cluster Operator
        └── Namespace: database
              ├── PostgreSQL 13  (wal_level=logical)
              └── MongoDB 5.0   (ReplicaSet rs0)
```

### Port Mappings (Host to Cluster)

Defined in [infrastructure/kind-config.yaml](../infrastructure/kind-config.yaml):

| Host Port | NodePort | Service |
|---|---|---|
| `8080` | 30000 | Airflow Web UI (Phase 4) |
| `5432` | 30001 | PostgreSQL |
| `8123` | 8123 | ClickHouse HTTP API (Phase 4) |

---

## Key Files

| File | Purpose |
|---|---|
| [infrastructure/kind-config.yaml](../infrastructure/kind-config.yaml) | Kind cluster definition with port mappings |
| [infrastructure/postgres.yaml](../infrastructure/postgres.yaml) | PostgreSQL Deployment + Service (`postgres-postgresql`) |
| [infrastructure/mongo.yaml](../infrastructure/mongo.yaml) | MongoDB Deployment + Service (`mongo-mongodb`) with replica set init lifecycle hook |
| [infrastructure/secrets.yaml](../infrastructure/secrets.yaml) | Kubernetes Secrets for DB passwords (mounted into Connect in Phase 3) |
| [scripts/seed_postgres.sql](../scripts/seed_postgres.sql) | Creates `users` table and inserts 4 seed rows |
| [scripts/seed_mongo.js](../scripts/seed_mongo.js) | Seeds 5 events into `commerce.events` collection |

---

## Deployment Steps

### 1. Create the Kind Cluster

```bash
kind create cluster --config infrastructure/kind-config.yaml --name data-engineering-challenge
```

Verify the node is Ready:

```bash
kubectl get nodes
# NAME                                       STATUS   ROLES           AGE
# data-engineering-challenge-control-plane    Ready    control-plane   ...
```

### 2. Create Namespaces

```bash
kubectl create namespace kafka
kubectl create namespace database
```

### 3. Install Strimzi Operator

```bash
kubectl apply -f https://strimzi.io/install/latest?namespace=kafka -n kafka
kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=120s
```

### 4. Deploy Databases

```bash
kubectl apply -f infrastructure/secrets.yaml
kubectl apply -f infrastructure/postgres.yaml
kubectl apply -f infrastructure/mongo.yaml
```

Wait for pods to reach Running:

```bash
kubectl get pods -n database -w
```

### 5. Initialize MongoDB Replica Set

The `mongo.yaml` includes a `postStart` lifecycle hook that auto-initializes the replica set. If it fails (common on first boot), initialize manually:

```bash
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')

# Initialize replica set
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'mongo-mongodb.database.svc.cluster.local:27017'}]})"

# Create root user (MONGO_INITDB vars may not work before rs.initiate)
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "db.getSiblingDB('admin').createUser({user: 'root', pwd: 'password123', roles: [{role: 'root', db: 'admin'}]})"
```

### 6. Seed the Databases

```bash
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')

# PostgreSQL — creates users table with 4 rows
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -f /dev/stdin < scripts/seed_postgres.sql

# MongoDB — seeds 5 events into commerce.events
kubectl exec -n database $MONGO_POD -- \
  mongosh "mongodb://root:password123@localhost:27017/?authSource=admin" \
  --file /dev/stdin < scripts/seed_mongo.js
```

---

## Seed Data

### PostgreSQL: `users` Table

| user_id | full_name | email |
|---|---|---|
| 1 | Alice Smith | alice@example.com |
| 2 | Bob A. Jones | bob@example.com |
| 3 | Charlie Brown | charlie@example.com |
| 4 | Diana Prince | diana@example.com |

Note: Bob's name is updated from "Bob Jones" to "Bob A. Jones" by the seed script, generating both an INSERT and an UPDATE event for CDC.

### MongoDB: `commerce.events` Collection

| user_id | event_type | metadata |
|---|---|---|
| 1 | login | `{ device: "mobile" }` |
| 1 | view_item | `{ item_id: "A100" }` |
| 2 | login | `{ device: "desktop" }` |
| 2 | add_to_cart | `{ item_id: "B200", quantity: 1 }` |
| 3 | login | `{ device: "tablet" }` |

---

## Database Configuration Details

### PostgreSQL

- **WAL level**: Set to `logical` via container args (`-c wal_level=logical`), required for Debezium to create replication slots
- **Authentication**: `postgres` / `password123`
- **Service DNS**: `postgres-postgresql.database.svc.cluster.local:5432`

### MongoDB

- **Replica Set**: `rs0` — required for Debezium's change stream capture mode
- **Started with**: `--replSet rs0 --bind_ip_all`
- **Authentication**: `root` / `password123` (authSource: `admin`)
- **Service DNS**: `mongo-mongodb.database.svc.cluster.local:27017`

---

## Verification

```bash
# Kind cluster is running
kubectl get nodes

# Strimzi operator is ready
kubectl get deployment -n kafka strimzi-cluster-operator

# Database pods are running
kubectl get pods -n database

# PostgreSQL is accessible and has data
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c "SELECT * FROM users ORDER BY user_id;"

# PostgreSQL WAL level is set correctly
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c "SHOW wal_level;"
# Expected: logical

# MongoDB replica set is PRIMARY
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $MONGO_POD -- mongosh --eval "rs.status().members[0].stateStr"
# Expected: PRIMARY

# MongoDB has seed data
kubectl exec -n database $MONGO_POD -- \
  mongosh "mongodb://root:password123@localhost:27017/?authSource=admin" \
  --eval "db.getSiblingDB('commerce').events.find().toArray()"
```

---

## Credentials Reference

| Service | Username | Password | Stored In |
|---|---|---|---|
| PostgreSQL | `postgres` | `password123` | `infrastructure/postgres.yaml` env vars + `secrets.yaml` |
| MongoDB | `root` | `password123` | `infrastructure/mongo.yaml` env vars + `secrets.yaml` |
| ClickHouse | `default` | `password123` | `infrastructure/clickhouse.yaml` (Phase 4) |
| ClickHouse | `airflow` | `airflow123` | `infrastructure/clickhouse.yaml` (Phase 4) |
