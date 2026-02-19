# How to Test and Operate — User Manual

This guide explains everything about how the CDC data pipeline works and how to operate it day-to-day. It covers starting up, verifying health, testing data flow, accessing services, running queries, injecting test data, and recovering from failures.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Cluster Management](#2-cluster-management)
3. [Health Checks — Verifying Everything Is Up](#3-health-checks--verifying-everything-is-up)
4. [Accessing the Services](#4-accessing-the-services)
5. [Working with PostgreSQL](#5-working-with-postgresql)
6. [Working with MongoDB](#6-working-with-mongodb)
7. [Working with Kafka](#7-working-with-kafka)
8. [Working with Kafka Connect and Debezium](#8-working-with-kafka-connect-and-debezium)
9. [Testing the CDC Pipeline End-to-End](#9-testing-the-cdc-pipeline-end-to-end)
10. [Working with ClickHouse](#10-working-with-clickhouse)
11. [Common Operational Tasks](#11-common-operational-tasks)
12. [Troubleshooting Guide](#12-troubleshooting-guide)

---

## 1. System Overview

### What Is Running and Where

The pipeline runs entirely inside a single-node Kind cluster (Docker container acting as a Kubernetes node). All services are organized into two Kubernetes namespaces:

| Namespace | What Lives There |
|---|---|
| `kafka` | Strimzi operator, Kafka broker, Kafka Connect, credential Secrets |
| `database` | PostgreSQL, MongoDB, ClickHouse |

### Port Mappings (Host → Cluster)

The `kind-config.yaml` exposes these ports directly on your machine:

| Host Port | Goes To | Service |
|---|---|---|
| `8080` | NodePort 30000 | Airflow Web UI |
| `5432` | NodePort 30001 | PostgreSQL |
| `8123` | containerPort 8123 | ClickHouse HTTP API |

Kafka and MongoDB are only accessible from inside the cluster (via `kubectl exec` or `port-forward`).

### Full Service Inventory

| Service | Kubernetes Name | Namespace | Internal Address | Port |
|---|---|---|---|---|
| Kafka Broker | `my-cluster-my-pool-0` | `kafka` | `my-cluster-kafka-bootstrap.kafka.svc:9092` | 9092 |
| Kafka Connect | `my-connect-cluster-connect-0` | `kafka` | `my-connect-cluster-connect-svc.kafka.svc:8083` | 8083 |
| PostgreSQL | `postgres-postgresql` | `database` | `postgres-postgresql.database.svc:5432` | 5432 |
| MongoDB | `mongo-mongodb` | `database` | `mongo-mongodb.database.svc:27017` | 27017 |
| ClickHouse HTTP | `chi-clickhouse-my-cluster-0-0` | `database` | — | 8123 |
| ClickHouse Native | — | `database` | — | 9000 |

### Credentials

| Service | Username | Password |
|---|---|---|
| PostgreSQL | `postgres` | `password123` |
| MongoDB | `root` | `password123` |
| ClickHouse | `default` | `password123` |

These passwords are stored in Kubernetes Secrets (`postgres-credentials`, `mongo-credentials`) in the `kafka` namespace, and hardcoded in the ClickHouse CR for now. Do not use these credentials in a production environment.

---

## 2. Cluster Management

### Starting the Cluster (After a Machine Reboot)

Kind clusters persist across Docker Desktop restarts. After rebooting your machine, simply start Docker Desktop and the cluster should come back automatically. To verify:

```bash
kubectl get nodes
```

Expected output:
```
NAME                                  STATUS   ROLES           AGE
data-engineering-challenge-control-plane   Ready    control-plane   ...
```

If the node shows `NotReady`, wait 30-60 seconds for Docker Desktop to fully start.

### Stopping Everything (Without Destroying the Cluster)

You cannot "stop" individual Kubernetes pods long-term without deleting their controllers. If you want to free resources, the safest approach is to stop Docker Desktop, which pauses the entire cluster.

### Destroying and Recreating the Cluster

> **Warning**: This deletes everything — all data, all Kafka offsets, all deployed resources.

```bash
# Delete
./bin/kind.exe delete cluster --name data-engineering-challenge

# Recreate from scratch
./bin/kind.exe create cluster --config kind-config.yaml --name data-engineering-challenge
```

After recreating, you must redo the full deployment sequence (install Strimzi, deploy Kafka, build/load the Connect image, deploy databases, etc.).

### Checking the Cluster Context

If you have multiple Kubernetes contexts, make sure you're pointing at the right one:

```bash
kubectl config current-context
# Should return: kind-data-engineering-challenge

# If not, switch to it:
kubectl config use-context kind-data-engineering-challenge
```

---

## 3. Health Checks — Verifying Everything Is Up

Run these commands in order. If anything is not `Running` or `Ready`, see [Section 12 — Troubleshooting](#12-troubleshooting-guide).

### Step 1 — Check All Pods in Both Namespaces

```bash
kubectl get pods -n kafka
kubectl get pods -n database
```

**Expected `kafka` namespace output**:
```
NAME                                          READY   STATUS    RESTARTS
my-cluster-entity-operator-...               2/2     Running   0
my-cluster-my-pool-0                         1/1     Running   0
my-connect-cluster-connect-0                 1/1     Running   0
strimzi-cluster-operator-...                 1/1     Running   0
```

**Expected `database` namespace output**:
```
NAME                        READY   STATUS    RESTARTS
mongo-...                   1/1     Running   0
postgres-...                1/1     Running   0
```

> **Kafka Connect note**: The readiness probe has a 300-second (5-minute) initial delay. The pod will show `0/1 Running` for up to 5 minutes after starting before it becomes `1/1 Running`. This is normal — Connect IS running, it's just not yet marked Ready by Kubernetes.

### Step 2 — Check Kafka Connect Cluster

```bash
kubectl get kafkaconnect -n kafka
```

Expected output:
```
NAME                 DESIRED REPLICAS   READY
my-connect-cluster   1                  True
```

### Step 3 — Check Both CDC Connectors

```bash
kubectl get kafkaconnector -n kafka
```

Expected output:
```
NAME                 CLUSTER              CONNECTOR CLASS                                    MAX TASKS   READY
mongo-connector      my-connect-cluster   io.debezium.connector.mongodb.MongoDbConnector     1           True
postgres-connector   my-connect-cluster   io.debezium.connector.postgresql.PostgresConnector 1           True
```

Both connectors must show `READY=True`. If `READY` is blank or `False`, see [Connector Not Becoming READY](#connector-not-becoming-ready).

### Step 4 — Check Kafka Topics Exist

```bash
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

Expected topics:
```
__consumer_offsets
connect-cluster-configs
connect-cluster-offsets
connect-cluster-status
mongo.commerce.events
postgres.public.users
```

The last two (`mongo.commerce.events` and `postgres.public.users`) are the CDC data topics. They are created automatically by Debezium when the connectors first run.

### Step 5 — Verify Data Is in the CDC Topics

```bash
# Count messages in postgres topic
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic postgres.public.users \
  --time -1

# Count messages in mongo topic
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic mongo.commerce.events \
  --time -1
```

The output shows `<topic>:<partition>:<offset>`. The offset number is how many messages have been produced. After initial seeding, expect at least 4 in postgres (4 users) and 5 in mongo (5 events).

---

## 4. Accessing the Services

### Port-Forwarding (For Services Without Direct Host Ports)

For Kafka Connect REST API:
```bash
kubectl port-forward pod/my-connect-cluster-connect-0 8083:8083 -n kafka
# Now accessible at http://localhost:8083
# Press Ctrl+C to stop
```

For Kafka broker (if you want to use local Kafka tools):
```bash
kubectl port-forward svc/my-cluster-kafka-bootstrap 9092:9092 -n kafka
# Now accessible at localhost:9092
```

For MongoDB:
```bash
kubectl port-forward svc/mongo-mongodb 27017:27017 -n database
# Now accessible at localhost:27017
```

For ClickHouse (if the host port mapping isn't working):
```bash
kubectl port-forward svc/clickhouse-chi-clickhouse-my-cluster-0-0 8123:8123 -n database
```

### PostgreSQL — Direct Access from Host

PostgreSQL is mapped to host port 5432 via the Kind `extraPortMappings`. You can connect with any PostgreSQL client:

```bash
# Using psql from your machine (if installed)
psql -h localhost -p 5432 -U postgres -d postgres
# Password: password123

# Using kubectl exec (always works, no local tools needed)
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n database $POSTGRES_POD -- psql -U postgres
```

---

## 5. Working with PostgreSQL

### Connecting

```bash
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n database $POSTGRES_POD -- psql -U postgres
```

Once inside `psql`, the prompt is `postgres=#`.

### Viewing the Users Table

```sql
SELECT * FROM users ORDER BY user_id;
```

Expected after initial seeding:
```
 user_id |   full_name   |        email         |        created_at        |        updated_at
---------+---------------+----------------------+--------------------------+--------------------------
       1 | Alice Smith   | alice@example.com    | 2026-02-19 ...           | 2026-02-19 ...
       2 | Bob A. Jones  | bob@example.com      | 2026-02-19 ...           | 2026-02-19 ...
       3 | Charlie Brown | charlie@example.com  | 2026-02-19 ...           | 2026-02-19 ...
       4 | Diana Prince  | diana@example.com    | 2026-02-19 ...           | 2026-02-19 ...
```

Note: Bob's name is `Bob A. Jones` (was updated by the seed script from `Bob Jones`).

### Checking WAL Replication Is Enabled

```sql
SHOW wal_level;
-- Expected: logical
```

This was set at container startup via the `args: ["-c", "wal_level=logical"]` in `postgres.yaml`. Without `wal_level=logical`, Debezium cannot create replication slots.

### Checking the Debezium Replication Slot

```sql
SELECT slot_name, plugin, active FROM pg_replication_slots;
```

Expected:
```
 slot_name | plugin   | active
-----------+----------+--------
 debezium  | pgoutput | t
```

- `slot_name = debezium` — Debezium's slot, created automatically on first connector start
- `plugin = pgoutput` — the built-in logical decoding output plugin (configured via `plugin.name: pgoutput`)
- `active = t` — the slot is actively being consumed by the connector

If the slot exists but `active = f`, the connector has stopped reading. If the slot does not exist at all, the connector has not started yet.

### Inserting a New User (Generates a CDC Event)

```sql
INSERT INTO users (full_name, email) VALUES ('Eve Wilson', 'eve@example.com');
```

This INSERT will appear in the `postgres.public.users` Kafka topic within a second as an `"op": "c"` (create) event.

### Updating a User (Generates a CDC Event)

```sql
UPDATE users SET full_name = 'Alice J. Smith', updated_at = NOW() WHERE email = 'alice@example.com';
```

This produces an `"op": "u"` (update) event with both `before` and `after` fields populated.

### Soft-Deleting a User

The challenge specifies deletes are soft-only (handled at the ClickHouse layer). In PostgreSQL you can still issue a hard DELETE and Debezium will emit a `"op": "d"` event:

```sql
DELETE FROM users WHERE email = 'eve@example.com';
```

The ClickHouse silver layer handles this by setting `is_deleted = 1` using `ReplacingMergeTree`.

### Exiting psql

```
\q
```

---

## 6. Working with MongoDB

### Connecting

```bash
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n database $MONGO_POD -- \
  mongosh "mongodb://root:password123@localhost:27017/?authSource=admin"
```

Once inside, the prompt is `rs0 [direct: primary]>`.

### Checking the Replica Set Status

```javascript
rs.status()
```

Key things to check:
- `members[0].stateStr` should be `"PRIMARY"`
- `members[0].name` should be `"mongo-mongodb.database.svc.cluster.local:27017"`

If the state is `STARTUP` or `STARTUP2`, wait a few seconds and try again.

### Viewing the Events Collection

```javascript
use commerce
db.events.find().pretty()
```

Expected after seeding:
```json
[
  { "user_id": 1, "event_type": "login",        "metadata": { "device": "mobile" } },
  { "user_id": 1, "event_type": "view_item",     "metadata": { "item_id": "A100" } },
  { "user_id": 2, "event_type": "login",         "metadata": { "device": "desktop" } },
  { "user_id": 2, "event_type": "add_to_cart",   "metadata": { "item_id": "B200", "quantity": 1 } },
  { "user_id": 3, "event_type": "login",         "metadata": { "device": "tablet" } }
]
```

### Inserting a New Event (Generates a CDC Event)

```javascript
use commerce
db.events.insertOne({
  user_id: 4,
  event_type: "purchase",
  timestamp: new Date(),
  metadata: { item_id: "C300", amount: 49.99 }
})
```

This appears in the `mongo.commerce.events` Kafka topic as an `"op": "c"` event.

### Updating an Event (Generates a CDC Event)

```javascript
db.events.updateOne(
  { user_id: 1, event_type: "login" },
  { $set: { "metadata.device": "tablet" } }
)
```

Because the connector uses `capture.mode: change_streams_update_full`, the full updated document is included in the `after` field of the CDC event (not just the delta).

### Exiting mongosh

```
exit
```

---

## 7. Working with Kafka

All Kafka operations run via `kubectl exec` into the Kafka broker pod. The broker pod name is always `my-cluster-my-pool-0`.

```bash
# Shortcut — set the broker pod name once
KAFKA_POD=my-cluster-my-pool-0
KAFKA_NS=kafka
BOOTSTRAP=localhost:9092
```

### List All Topics

```bash
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP --list
```

### Describe a Topic (Partitions, Offsets, Retention)

```bash
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server $BOOTSTRAP \
  --describe \
  --topic postgres.public.users
```

### Read All Messages From the Beginning

```bash
# Read all 4 users from the postgres CDC topic
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server $BOOTSTRAP \
  --topic postgres.public.users \
  --from-beginning \
  --max-messages 10 \
  --timeout-ms 10000

# Read all 5 events from the mongo CDC topic
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server $BOOTSTRAP \
  --topic mongo.commerce.events \
  --from-beginning \
  --max-messages 10 \
  --timeout-ms 10000
```

### Watch Live Messages (Tail Mode)

Leave this running in a terminal window, then make changes in PostgreSQL or MongoDB in another window to watch CDC events appear in real time:

```bash
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server $BOOTSTRAP \
  --topic postgres.public.users
# Ctrl+C to stop
```

### Read Messages With Keys

Debezium uses the primary key as the Kafka message key. For PostgreSQL, each message key is the `user_id`. To see keys alongside values:

```bash
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server $BOOTSTRAP \
  --topic postgres.public.users \
  --from-beginning \
  --property print.key=true \
  --property key.separator=" | " \
  --max-messages 4 \
  --timeout-ms 10000
```

### Check Consumer Group Lag

Consumer group lag tells you how far behind a consumer is from the latest messages. A lag of 0 means the consumer has processed everything.

```bash
# List all consumer groups
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server $BOOTSTRAP \
  --list

# Check lag for a specific group
kubectl exec -n $KAFKA_NS $KAFKA_POD -- \
  /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server $BOOTSTRAP \
  --describe \
  --group ch_users_consumer
```

The ClickHouse consumer groups (`ch_users_consumer`, `ch_events_consumer`) appear here when ClickHouse is reading from Kafka.

### Understanding the CDC Message Format

Every Debezium message has this envelope structure:

```json
{
  "before": { ... },   // State before the change (null for inserts and snapshots)
  "after":  { ... },   // State after the change  (null for deletes)
  "op":     "r|c|u|d", // r=snapshot read, c=insert, u=update, d=delete
  "source": {
    "version": "2.7.0.Final",
    "connector": "postgresql",
    "table": "users",
    "lsn": 23068480,   // PostgreSQL WAL Log Sequence Number
    "ts_ms": ...       // Timestamp in milliseconds
  },
  "ts_ms": ...         // When Debezium processed the event
}
```

**For deletes**: `after` is `null`. The deleted row's data is in `before`. ClickHouse must read from `before` to get the `user_id` when `op = 'd'`.

**PostgreSQL timestamp fields**: Debezium encodes `TIMESTAMP` columns as **microseconds since epoch** (not milliseconds). To convert in ClickHouse: `toDateTime(updated_at / 1000000)`.

---

## 8. Working with Kafka Connect and Debezium

### The Kafka Connect REST API

All connector management happens through the Connect REST API on port 8083. Always set up port-forward first:

```bash
kubectl port-forward pod/my-connect-cluster-connect-0 8083:8083 -n kafka &
# Wait 2 seconds, then run your commands
# When done: kill %1 (or Ctrl+C)
```

### Check Connect Is Running

```bash
curl http://localhost:8083/
```

Expected response:
```json
{
  "version": "4.0.0",
  "commit": "985bc99521dd22bb",
  "kafka_cluster_id": "F8s5FQOBQhyk8I8dJotOiA"
}
```

### List All Connectors

```bash
curl http://localhost:8083/connectors
```

Expected: `["postgres-connector","mongo-connector"]`

### Check Connector Status (Detailed)

```bash
curl http://localhost:8083/connectors/postgres-connector/status
curl http://localhost:8083/connectors/mongo-connector/status
```

A healthy connector shows:
```json
{
  "name": "postgres-connector",
  "connector": { "state": "RUNNING", "worker_id": "..." },
  "tasks": [{ "id": 0, "state": "RUNNING", "worker_id": "..." }],
  "type": "source"
}
```

If `tasks[0].state` is `"FAILED"`, the `trace` field shows the full Java stack trace with the root cause.

### Restart a Failed Connector Task

```bash
curl -X POST http://localhost:8083/connectors/postgres-connector/tasks/0/restart
curl -X POST http://localhost:8083/connectors/mongo-connector/tasks/0/restart
```

### Pause and Resume a Connector

```bash
# Pause (stops consuming from source database)
curl -X PUT http://localhost:8083/connectors/postgres-connector/pause
curl -X PUT http://localhost:8083/connectors/mongo-connector/pause

# Resume
curl -X PUT http://localhost:8083/connectors/postgres-connector/resume
curl -X PUT http://localhost:8083/connectors/mongo-connector/resume
```

Pausing is useful when you want to make bulk changes to the source database without flooding Kafka.

### View Current Connector Configuration

```bash
curl http://localhost:8083/connectors/postgres-connector/config
curl http://localhost:8083/connectors/mongo-connector/config
```

### View Available Connector Plugins

```bash
curl http://localhost:8083/connector-plugins
```

This lists all connector classes registered in `/opt/kafka/plugins/`. You should see `io.debezium.connector.postgresql.PostgresConnector` and `io.debezium.connector.mongodb.MongoDbConnector`.

### How the Strimzi Operator Manages Connectors

The Strimzi operator reads `KafkaConnector` custom resources and submits their `config` section to the Connect REST API. It reconciles every ~2 minutes. This means:

- If you change a connector config via `kubectl apply`, the operator picks it up within ~2 minutes and pushes it to the REST API.
- If you change a connector config directly via the REST API (`curl -X PUT ...`), the operator will **overwrite** your change at the next reconciliation cycle with whatever is in the `KafkaConnector` CR.

**Rule**: Always edit connector config in the YAML files (`postgres-connector.yaml`, `mongo-connector.yaml`) and `kubectl apply` them. Don't rely on direct REST API changes surviving.

### How Secrets Are Injected Into Connectors

Database passwords are stored in Kubernetes Secrets:
```
Secret: postgres-credentials (namespace: kafka)
  Key: password
  Value: password123

Secret: mongo-credentials (namespace: kafka)
  Key: password
  Value: password123
```

These secrets are mounted as files into the Connect pod at:
- `/mnt/postgres-auth/password` (contains the string `password123`)
- `/mnt/mongo-auth/password` (contains the string `password123`)

The connector configs reference them using the `strimzidir` config provider:
```
"${strimzidir:/mnt/postgres-auth:password}"
```

`strimzidir` is Strimzi's `DirectoryConfigProvider` — it opens the directory `/mnt/postgres-auth`, reads the file named `password`, and returns its raw content as the config value.

The `allowed.paths: /opt/kafka,/mnt` setting in `kafka-connect.yaml` explicitly permits the provider to read from `/mnt`.

---

## 9. Testing the CDC Pipeline End-to-End

This is the most important operational test. It confirms that a change in a source database flows all the way through to a Kafka topic.

### Test 1 — PostgreSQL INSERT

**Terminal 1** — Start watching the Kafka topic:
```bash
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.users
```

**Terminal 2** — Insert a row in PostgreSQL:
```bash
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c \
  "INSERT INTO users (full_name, email) VALUES ('Test User', 'test@example.com');"
```

**Expected result in Terminal 1** (within ~1 second):
```json
{
  "before": null,
  "after": {
    "user_id": 5,
    "full_name": "Test User",
    "email": "test@example.com",
    "created_at": ...,
    "updated_at": ...
  },
  "op": "c",
  "source": { "connector": "postgresql", "table": "users", ... }
}
```

### Test 2 — PostgreSQL UPDATE

**Terminal 1** — Keep the consumer running from Test 1.

**Terminal 2**:
```bash
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c \
  "UPDATE users SET full_name='Test User Updated', updated_at=NOW() WHERE email='test@example.com';"
```

**Expected result in Terminal 1**:
```json
{
  "before": { "user_id": 5, "full_name": "Test User", ... },
  "after":  { "user_id": 5, "full_name": "Test User Updated", ... },
  "op": "u"
}
```

Both `before` and `after` are populated for updates.

### Test 3 — PostgreSQL DELETE

```bash
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c \
  "DELETE FROM users WHERE email='test@example.com';"
```

**Expected result** — two consecutive messages:

1. The delete event:
```json
{
  "before": { "user_id": 5, "full_name": "Test User Updated", ... },
  "after": null,
  "op": "d"
}
```

2. A tombstone (null value with the deleted key) — Kafka's mechanism for log compaction to clean up deleted keys.

### Test 4 — MongoDB INSERT

**Terminal 1** — Watch the mongo topic:
```bash
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic mongo.commerce.events
```

**Terminal 2**:
```bash
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $MONGO_POD -- \
  mongosh "mongodb://root:password123@localhost:27017/?authSource=admin" \
  --eval "db.getSiblingDB('commerce').events.insertOne({user_id: 99, event_type: 'test_event', timestamp: new Date()})"
```

**Expected result in Terminal 1** (within ~1-2 seconds):
```json
{
  "before": null,
  "after": "{\"_id\": ..., \"user_id\": 99, \"event_type\": \"test_event\", \"timestamp\": ...}",
  "op": "c",
  "source": { "connector": "mongodb", "collection": "events", ... }
}
```

> **MongoDB note**: The `after` field for MongoDB events is a JSON string (not a nested object), because MongoDB documents are schema-free. You need to `JSON_EXTRACT` or `JSONExtract()` inside ClickHouse to parse it.

### Test 5 — Measure End-to-End Latency

```bash
# Record the time before the insert
date

# Insert with a known value
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c \
  "INSERT INTO users (full_name, email) VALUES ('Latency Test', 'latency@example.com');"

# In your Kafka consumer terminal, note the ts_ms in the received message
# Compare to the current time — typical latency is under 1 second
```

---

## 10. Working with ClickHouse

> **Note**: ClickHouse (Phase 4) may not be deployed yet. This section covers how to use it once deployed.

### Checking ClickHouse Is Deployed

```bash
kubectl get pods -n database | grep clickhouse
```

### Connecting to ClickHouse

ClickHouse HTTP API is accessible on host port 8123 (mapped in `kind-config.yaml`):

```bash
# Test the connection
curl http://localhost:8123/ping
# Expected: Ok.

# Run a query via HTTP
curl "http://localhost:8123/?user=default&password=password123" \
  --data "SELECT version()"
```

Or from inside the cluster:
```bash
CH_POD=$(kubectl get pod -n database -l app=clickhouse -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n database $CH_POD -- clickhouse-client --password password123
```

### Viewing Tables

```sql
SHOW TABLES;
```

Expected tables after schema deployment:
- `users_queue` — Kafka engine (Bronze layer, reads from `postgres.public.users`)
- `users_silver` — ReplacingMergeTree (Silver layer, deduplicated users)
- `mv_users` — Materialized View (auto-populates `users_silver`)
- `events_queue` — Kafka engine (Bronze layer, reads from `mongo.commerce.events`)
- `events_silver` — MergeTree (Silver layer, raw events)
- `mv_events` — Materialized View (auto-populates `events_silver`)

### Querying Silver Tables

```sql
-- Current state of all users (most recent version of each)
SELECT user_id, full_name, email, updated_at
FROM users_silver FINAL
WHERE is_deleted = 0
ORDER BY user_id;

-- All events
SELECT user_id, event_type, timestamp
FROM events_silver
ORDER BY timestamp DESC
LIMIT 20;
```

> `FINAL` is required with `ReplacingMergeTree` to get deduplicated results. Without `FINAL`, you may see duplicate rows from merge operations that haven't completed yet.

### How the ClickHouse Bronze → Silver Pipeline Works

1. `users_queue` (Kafka Engine table) connects to Kafka and reads raw CDC JSON messages from `postgres.public.users`
2. The Materialized View `mv_users` fires automatically for every batch of messages consumed from `users_queue`
3. `mv_users` parses the Debezium JSON envelope and writes into `users_silver` (`ReplacingMergeTree`, deduplicated by `user_id`, versioned by `ts_ms`)
4. The same pattern applies to events: `events_queue` → `mv_events` → `events_silver`

### Testing ClickHouse Is Consuming From Kafka

```sql
-- This reads directly from Kafka (consumes messages from the topic)
-- Only useful for debugging — do not run frequently as it advances the consumer offset
SELECT * FROM users_queue LIMIT 5;
```

> **Warning**: Querying a Kafka Engine table directly consumes messages from the topic and advances the consumer group offset. Those messages will NOT be processed by the Materialized View. Use this for debugging only.

---

## 11. Common Operational Tasks

### Restart the Strimzi Operator (Fixes Stuck Reconciliation)

The Strimzi operator can get stuck in "Reconciliation is in progress" after a crash loop. Deleting the operator pod forces a fresh start:

```bash
kubectl delete pod -n kafka -l strimzi.io/kind=cluster-operator
```

The operator deployment will automatically create a new pod within seconds.

### Restart Kafka Connect

```bash
kubectl delete pod -n kafka my-connect-cluster-connect-0
```

The Strimzi `StrimziPodSet` controller will recreate the pod automatically. Connectors resume from their saved offsets in the Kafka backing topics, so no data is lost.

> **Note**: After restart, wait 5 minutes for the readiness probe before the pod shows `1/1 Running`.

### Reset a Connector (Force Full Re-Snapshot)

If you need Debezium to re-read all data from scratch:

```bash
# Set up port-forward first
kubectl port-forward pod/my-connect-cluster-connect-0 8083:8083 -n kafka &

# 1. Delete the connector
curl -X DELETE http://localhost:8083/connectors/postgres-connector

# 2. Drop the PostgreSQL replication slot (if resetting postgres connector)
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c \
  "SELECT pg_drop_replication_slot('debezium');"

# 3. Delete offsets from Kafka (reset the connector's saved position)
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --delete \
  --topic connect-cluster-offsets

# 4. Restart Kafka Connect to recreate the backing topics
kubectl delete pod -n kafka my-connect-cluster-connect-0

# 5. Wait for Connect to be ready, then redeploy connector
kubectl apply -f infrastructure/postgres-connector.yaml
```

> **Warning**: Resetting a connector re-reads all historical data. If ClickHouse is consuming, you will get duplicate rows in silver tables unless you also truncate them.

### Check and Clean Up Stale Replication Slots

If a connector crashes and doesn't clean up, PostgreSQL keeps the replication slot open. Stale slots cause WAL files to accumulate and can fill the disk:

```bash
POSTGRES_POD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c \
  "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
   FROM pg_replication_slots;"
```

If a slot is `active = f` (inactive) and accumulating WAL, drop it:

```bash
kubectl exec -n database $POSTGRES_POD -- psql -U postgres -c \
  "SELECT pg_drop_replication_slot('debezium');"
```

### View Kafka Connect Logs

```bash
# Last 100 lines
kubectl logs pod/my-connect-cluster-connect-0 -n kafka --tail=100

# Follow live logs
kubectl logs pod/my-connect-cluster-connect-0 -n kafka -f

# Previous pod's logs (if the pod restarted)
kubectl logs pod/my-connect-cluster-connect-0 -n kafka --previous
```

### Update the Connect Image

When the `Dockerfile.final` changes:

1. Build with a new tag (do NOT reuse the same tag):
```bash
docker build -f infrastructure/Dockerfile.final -t my-final-connect:1.2 .
```

2. Load into Kind:
```bash
./bin/kind.exe load docker-image my-final-connect:1.2 --name data-engineering-challenge
```

3. Update `kafka-connect.yaml` to reference the new tag:
```yaml
image: my-final-connect:1.2
```

4. Apply:
```bash
kubectl apply -f infrastructure/kafka-connect.yaml
```

The operator will rolling-restart the Connect pod with the new image.

---

## 12. Troubleshooting Guide

### Connect Pod in CrashLoopBackOff

```bash
# Check the crash reason
kubectl logs pod/my-connect-cluster-connect-0 -n kafka --previous
```

**Symptom A: `log4j:ERROR Could not read configuration file from URL [file:/opt/kafka/custom-config/log4j.properties]`**

Root cause: `slf4j-reload4j.jar` from Debezium is on the classpath and conflicts with Strimzi's log4j2. This was fixed in `Dockerfile.final` by removing the JAR, but if you rebuild the image without bumping the tag, Kind may be serving the old cached version.

Fix: Bump the image tag (`1.2`, `1.3`, etc.), rebuild, reload into Kind, update `kafka-connect.yaml`.

**Symptom B: Exit Code 127 / `kafka_connect_run.sh: not found`**

Root cause: The image is a plain Debezium image, not the Strimzi hybrid image. Strimzi requires its own startup script.

Fix: Ensure you're building from `Dockerfile.final` (which uses `quay.io/strimzi/kafka:0.50.0-kafka-4.0.0` as base), not `Dockerfile.connect`.

### Connector Not Becoming READY

```bash
# Check the Strimzi operator logs to see the error
kubectl logs -n kafka -l strimzi.io/kind=cluster-operator --tail=50
```

**Symptom: `PUT /connectors/.../config returned 400: Connector configuration is invalid`**

The operator tried to create/update the connector via the REST API but Connect rejected the config. The operator log will contain the specific validation error message.

Common causes and fixes:

| Error message | Cause | Fix |
|---|---|---|
| `Invalid connection string` | MongoDB connection string missing `replicaSet=rs0` or password is empty | Check `${strimzidir:...}` resolves correctly; add `&replicaSet=rs0` to connection string |
| `could not access file "decoderbufs"` | PostgreSQL connector defaulting to `decoderbufs` plugin | Add `plugin.name: pgoutput` to connector config |
| `replication slot "debezium" already exists` | Old slot left over from a previous failed attempt | Drop the slot: `SELECT pg_drop_replication_slot('debezium');` in psql |
| `password authentication failed` | Wrong password or `${strimzidir:...}` resolved to empty | Verify the secret file exists at `/mnt/postgres-auth/password` inside the Connect pod |
| `The connection attempt failed` | Database pod not running or wrong hostname | Check `kubectl get pods -n database` |

**Symptom: `READY` column is blank (not True or False)**

The operator hasn't reconciled this connector yet. Usually happens after the Connect pod restarts (waiting for the 300s readiness probe). Wait 5-6 minutes, then check again.

**Symptom: Connector is READY but `kubectl get kafkaconnector` still shows it**

This is normal — the CRD always shows up, even when things are working. `READY=True` is the success state.

### Strimzi Operator Stuck ("Reconciliation is in progress")

```bash
kubectl logs -n kafka -l strimzi.io/kind=cluster-operator --tail=20
```

If you see `Reconciliation is in progress` repeated for minutes, the operator is waiting for a pod that will never become ready. Fix by restarting the operator:

```bash
kubectl delete pod -n kafka -l strimzi.io/kind=cluster-operator
```

### MongoDB Auth Failure After Restart

**Problem**: If the MongoDB pod restarts, the auth state may be lost (the root user exists only in the WiredTiger data files, which are ephemeral in this setup — `mongo.yaml` uses no PersistentVolumeClaim).

**Check**:
```bash
MONGO_POD=$(kubectl get pod -n database -l app=mongo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n database $MONGO_POD -- mongosh --eval "db.adminCommand({ping:1})"
```

If authentication fails, recreate the user:
```bash
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "db.getSiblingDB('admin').createUser({user:'root',pwd:'password123',roles:[{role:'root',db:'admin'}]})"
```

Also check the replica set is still initialized:
```bash
kubectl exec -n database $MONGO_POD -- mongosh --eval "rs.status().members[0].stateStr"
# Should be: PRIMARY
```

If not, re-initialize:
```bash
kubectl exec -n database $MONGO_POD -- mongosh --eval \
  "rs.initiate({_id:'rs0',members:[{_id:0,host:'mongo-mongodb.database.svc.cluster.local:27017'}]})"
```

### Kafka Topics Are Empty After Connector Is READY

This can happen if the connector's saved offset in `connect-cluster-offsets` is at the end of the topic, so it doesn't re-snapshot.

Check the connector's offset:
```bash
kubectl port-forward pod/my-connect-cluster-connect-0 8083:8083 -n kafka &
curl http://localhost:8083/connectors/postgres-connector/offsets
```

If the offset exists and points to a recent LSN, the connector won't re-read old data. New changes in the source database will still appear.

To force a re-snapshot, see [Reset a Connector](#reset-a-connector-force-full-re-snapshot) in Section 11.

### Pod Is Using Old Cached Image Despite Rebuild

**Symptom**: You rebuilt the Docker image but the pod still runs the old version.

**Diagnosis**:
```bash
kubectl get pod my-connect-cluster-connect-0 -n kafka \
  -o jsonpath='{.status.containerStatuses[0].imageID}'
```

Compare the digest shown to your new build's digest (`docker images --digests my-final-connect`).

**Fix**: Always use a new tag. Kind caches images by tag — loading the same tag does not replace the cached image.

### "No such file or directory" When Using port-forward on Windows

Git Bash on Windows can translate paths in command arguments. If you see path mangling (e.g., `/n` becoming `\n`), prefix paths with double slashes: `//opt//kafka//bin//...`.

Alternatively, wrap the path in quotes inside the `--eval` string.

---

## Quick Reference Card

### Most-Used Commands

```bash
# == STATUS ==
kubectl get pods -n kafka                          # All Kafka components
kubectl get pods -n database                       # All databases
kubectl get kafkaconnector -n kafka                # CDC connector health

# == DATABASES ==
PGPOD=$(kubectl get pod -n database -l app=postgres -o jsonpath='{.items[0].metadata.name}')
MGPOD=$(kubectl get pod -n database -l app=mongo   -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it -n database $PGPOD -- psql -U postgres        # PostgreSQL shell
kubectl exec -it -n database $MGPOD -- mongosh \
  "mongodb://root:password123@localhost:27017/?authSource=admin" # MongoDB shell

# == KAFKA ==
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list    # List topics

kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic postgres.public.users \
  --from-beginning --max-messages 10 --timeout-ms 10000         # Read topic

# == KAFKA CONNECT REST API ==
kubectl port-forward pod/my-connect-cluster-connect-0 8083:8083 -n kafka &
curl http://localhost:8083/                                       # Cluster info
curl http://localhost:8083/connectors                            # List connectors
curl http://localhost:8083/connectors/postgres-connector/status  # Connector status

# == RECOVERY ==
kubectl delete pod -n kafka -l strimzi.io/kind=cluster-operator  # Unstick operator
kubectl delete pod -n kafka my-connect-cluster-connect-0         # Restart Connect

# == LOGS ==
kubectl logs pod/my-connect-cluster-connect-0 -n kafka --tail=50    # Connect logs
kubectl logs -n kafka -l strimzi.io/kind=cluster-operator --tail=50 # Operator logs
```
