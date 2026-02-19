# Phase 3: Multi-Source CDC Pipeline

## Objective

Establish a real-time Change Data Capture (CDC) pipeline that streams every insert, update, and delete from PostgreSQL and MongoDB into Kafka topics with high fidelity. This is the backbone of the entire data platform — downstream consumers (ClickHouse, Airflow) depend on this stream being reliable.

---

## Components Deployed

| Component | Resource | Namespace |
|---|---|---|
| Kafka Cluster | `my-cluster` (KRaft, 1 broker) | `kafka` |
| Kafka Connect | `my-connect-cluster` (1 replica) | `kafka` |
| PostgreSQL | `postgres` (Deployment + Service) | `database` |
| MongoDB | `mongo` (Deployment + Service, ReplicaSet `rs0`) | `database` |
| Postgres Connector | `postgres-connector` (KafkaConnector CR) | `kafka` |
| Mongo Connector | `mongo-connector` (KafkaConnector CR) | `kafka` |

---

## Architecture

```
PostgreSQL (wal_level=logical)
    └── Debezium PostgreSQL Connector
            └── Kafka Topic: postgres.public.users

MongoDB (ReplicaSet rs0)
    └── Debezium MongoDB Connector
            └── Kafka Topic: mongo.commerce.events

Both connectors run inside Kafka Connect
managed by the Strimzi Operator on Kind.
```

### The Connect Image Strategy

The Strimzi operator manages Kafka Connect pods and injects its own startup script (`/opt/kafka/kafka_connect_run.sh`). Off-the-shelf Debezium images do not include this script, so a **hybrid image** was required:

- **Base**: `quay.io/strimzi/kafka:0.50.0-kafka-4.0.0` — provides the Strimzi startup scripts and log4j2 logging setup
- **Plugins**: Debezium PostgreSQL and MongoDB connectors (v2.7.0.Final) downloaded manually into `/opt/kafka/plugins/`

See [infrastructure/Dockerfile.final](../infrastructure/Dockerfile.final).

---

## Key Files

| File | Purpose |
|---|---|
| [infrastructure/Dockerfile.final](../infrastructure/Dockerfile.final) | Hybrid Connect image definition |
| [infrastructure/kafka-connect.yaml](../infrastructure/kafka-connect.yaml) | KafkaConnect CR — uses `my-final-connect:1.1` |
| [infrastructure/kraft-cluster.yaml](../infrastructure/kraft-cluster.yaml) | Kafka cluster (KRaft, version 4.0.0) |
| [infrastructure/postgres.yaml](../infrastructure/postgres.yaml) | PostgreSQL 13 Deployment + Service |
| [infrastructure/mongo.yaml](../infrastructure/mongo.yaml) | MongoDB 5.0 Deployment + Service |
| [infrastructure/secrets.yaml](../infrastructure/secrets.yaml) | DB credentials (Kubernetes Secrets) |
| [infrastructure/postgres-connector.yaml](../infrastructure/postgres-connector.yaml) | Debezium PostgreSQL KafkaConnector |
| [infrastructure/mongo-connector.yaml](../infrastructure/mongo-connector.yaml) | Debezium MongoDB KafkaConnector |
| [scripts/seed_postgres.sql](../scripts/seed_postgres.sql) | Creates and populates the `users` table |
| [scripts/seed_mongo.js](../scripts/seed_mongo.js) | Populates the `commerce.events` collection |

---

## Deployment Steps

### 1. Build the Hybrid Connect Image

```bash
docker build -f infrastructure/Dockerfile.final -t my-final-connect:1.1 .
```

### 2. Load Image into Kind

```bash
./bin/kind.exe load docker-image my-final-connect:1.1 --name data-engineering-challenge
```

> **Note**: Always use a new tag when updating the image. Kind caches images by tag and will not reload the same tag even if the image digest has changed.

### 3. Deploy Databases

```bash
kubectl create namespace database
kubectl apply -f infrastructure/postgres.yaml
kubectl apply -f infrastructure/mongo.yaml
```

Wait for both pods to reach `Running`:

```bash
kubectl get pods -n database
```

### 4. Initialize MongoDB Replica Set

The Debezium MongoDB connector requires a replica set. Initialize it after the pod is running:

```bash
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')

# Initialize replica set with the Kubernetes service DNS name
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'mongo-mongodb.database.svc.cluster.local:27017'}]})"

# Create the root user (MONGO_INITDB vars may not run before rs.initiate)
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "db.getSiblingDB('admin').createUser({user: 'root', pwd: 'password123', roles: [{role: 'root', db: 'admin'}]})"
```

### 5. Seed the Databases

```bash
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')

# PostgreSQL
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -f /dev/stdin < scripts/seed_postgres.sql

# MongoDB
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $MONGO_POD -- \
  mongosh "mongodb://root:password123@localhost:27017/?authSource=admin" \
  --file /dev/stdin < scripts/seed_mongo.js
```

### 6. Deploy Kafka Connect

```bash
kubectl apply -f infrastructure/secrets.yaml
kubectl apply -f infrastructure/kafka-connect.yaml
```

Wait for the pod to reach `1/1 Running` (readiness probe has a 300s initial delay):

```bash
kubectl get pods -n kafka -w
```

### 7. Deploy the Connectors

```bash
kubectl apply -f infrastructure/postgres-connector.yaml
kubectl apply -f infrastructure/mongo-connector.yaml
```

Verify both connectors are `READY=True`:

```bash
kubectl get kafkaconnector -n kafka
```

---

## Verification

### Check Connector Status

```bash
# Via Kubernetes CRD
kubectl get kafkaconnector -n kafka

# Via Connect REST API (requires port-forward)
kubectl port-forward pod/my-connect-cluster-connect-0 8083:8083 -n kafka &
curl http://localhost:8083/connectors?expand=status
```

### Check Kafka Topics

```bash
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

Expected topics:
- `postgres.public.users`
- `mongo.commerce.events`

### Sample CDC Messages

```bash
# PostgreSQL users CDC events
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.users \
  --from-beginning --max-messages 3 --timeout-ms 10000

# MongoDB events CDC events
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic mongo.commerce.events \
  --from-beginning --max-messages 3 --timeout-ms 10000
```

---

## Issues Encountered and Resolved

### 1. CrashLoopBackOff — `slf4j-reload4j` Classpath Conflict

**Root Cause**: Debezium 2.7.0 bundles `slf4j-reload4j.jar`, a log4j1 SLF4J binding. When the JVM scans `/opt/kafka/plugins/` at startup (before plugin isolation is established), this JAR bleeds into the main classpath and conflicts with Strimzi's log4j2 setup. The static initializer of `AbstractConnectCli` triggers `LoggerFactory.getLogger()`, which picks up the log4j1 binding and crashes immediately with:

```
log4j:ERROR Could not read configuration file from URL [file:/opt/kafka/custom-config/log4j.properties]
```

**Fix**: Remove the conflicting JARs in the Dockerfile:

```dockerfile
RUN find /opt/kafka/plugins/ -name "slf4j-reload4j-*.jar" -delete \
    && find /opt/kafka/plugins/ -name "reload4j-*.jar" -delete
```

### 2. Kind Image Caching

**Problem**: After rebuilding the Docker image with the slf4j fix, the pod continued using the old cached image (`sha256:34074db`) because Kind caches images by tag. `kind load docker-image my-final-connect:1.0` did not replace the cached version.

**Fix**: Always bump the image tag for each rebuild (`:1.0` → `:1.1`). Update `kafka-connect.yaml` to reference the new tag.

### 3. Strimzi Operator Stuck in Reconciliation

**Problem**: After the Connect pod crash-looped, the Strimzi operator's reconciliation timer (`operationTimeoutMs=300s`) left reconciliation "in progress", blocking new deployments.

**Fix**: Restart the operator pod:

```bash
kubectl delete pod -n kafka -l strimzi.io/kind=cluster-operator
```

### 4. KafkaConnect Version Mismatch

**Problem**: `kafka-connect.yaml` had `version: 3.7.0` while the Kafka cluster runs `4.0.0`. The operator generated a ConfigMap with `bootstrap.servers=` (empty), preventing Connect from connecting to Kafka.

**Fix**: Set `version: 4.0.0` in `kafka-connect.yaml` to match the Kafka cluster.

### 5. Secret File Provider Syntax

**Problem**: Kubernetes Secret volumes mount each key as a raw file (e.g., `/mnt/postgres-auth/password` contains `password123` as plain text). The `FileConfigProvider` (`${file:/path:key}`) interprets the file as a Java `.properties` file, so it looks for a `key=value` pair — and finds none, returning an empty value.

**Fix**: Use the `DirectoryConfigProvider` instead, which reads the file by name from a directory and returns its raw content:

```yaml
# In kafka-connect.yaml — extend allowed paths to /mnt
config.providers.strimzidir.param.allowed.paths: /opt/kafka,/mnt

# In connector config — use strimzidir instead of file
database.password: "${strimzidir:/mnt/postgres-auth:password}"
```

### 6. PostgreSQL Connector — `decoderbufs` Plugin Not Found

**Problem**: Debezium defaults to the `decoderbufs` output plugin for PostgreSQL logical replication. The `postgres:13` Docker image does not include this plugin.

**Fix**: Explicitly set `plugin.name: pgoutput`, which is built into PostgreSQL 10+ and requires no extra installation.

### 7. MongoDB Replica Set Hostname

**Problem**: Initializing the replica set with `localhost:27017` causes the Debezium connector (running in the Connect pod) to try connecting to `localhost` — which resolves to the Connect pod itself, not the MongoDB pod.

**Fix**: Initialize the replica set with the Kubernetes service DNS hostname:

```javascript
rs.initiate({
  _id: 'rs0',
  members: [{ _id: 0, host: 'mongo-mongodb.database.svc.cluster.local:27017' }]
})
```

Also include `replicaSet=rs0` in the MongoDB connection string:

```
mongodb://root:<pwd>@mongo-mongodb.database.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0
```

### 8. MongoDB Root User Not Created on First Boot

**Problem**: The `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD` environment variables failed to create the root user because the replica set was not initialized when the container's init scripts ran.

**Fix**: Create the root user manually after `rs.initiate()` completes:

```javascript
db.getSiblingDB('admin').createUser({
  user: 'root',
  pwd: 'password123',
  roles: [{ role: 'root', db: 'admin' }]
})
```

---

## Connector Configuration Reference

### PostgreSQL Connector

```yaml
connector.class: io.debezium.connector.postgresql.PostgresConnector
database.hostname: postgres-postgresql.database.svc.cluster.local
database.port: 5432
database.user: postgres
database.password: "${strimzidir:/mnt/postgres-auth:password}"
database.dbname: postgres
topic.prefix: postgres
table.include.list: public.users
plugin.name: pgoutput   # Required — decoderbufs is not in stock postgres:13
```

### MongoDB Connector

```yaml
connector.class: io.debezium.connector.mongodb.MongoDbConnector
mongodb.connection.string: "mongodb://root:${strimzidir:/mnt/mongo-auth:password}@mongo-mongodb.database.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0"
topic.prefix: mongo
collection.include.list: commerce.events
capture.mode: change_streams_update_full
```

---

## CDC Message Format

Both connectors emit Debezium-format JSON messages. Example from `postgres.public.users`:

```json
{
  "before": null,
  "after": {
    "user_id": 1,
    "full_name": "Alice Smith",
    "email": "alice@example.com",
    "created_at": 1771475741085385,
    "updated_at": 1771475741085385
  },
  "op": "r",
  "source": {
    "version": "2.7.0.Final",
    "connector": "postgresql",
    "name": "postgres",
    "snapshot": "first",
    "table": "users"
  }
}
```

Operations:
- `"op": "r"` — snapshot read (initial table scan)
- `"op": "c"` — insert
- `"op": "u"` — update (includes `before` and `after`)
- `"op": "d"` — delete (includes `before`, `after` is null)
