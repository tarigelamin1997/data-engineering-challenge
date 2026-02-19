# Phase 4: Gold Layer — ClickHouse + Airflow

## Objective

Deploy the analytical storage layer (ClickHouse) and the orchestration layer (Airflow) to:

1. Continuously consume CDC events from Kafka into Bronze/Silver ClickHouse tables
2. Run a daily Airflow DAG (`gold_user_activity`) that joins Silver tables and writes aggregated results to a Gold table

---

## Architecture

```
Kafka Topics
  postgres.public.users   ──► users_queue (Kafka Engine)  ──► mv_users ──► users_silver (ReplacingMergeTree)
  mongo.commerce.events   ──► events_queue (Kafka Engine) ──► mv_events ──► events_silver (MergeTree)
                                                                                    │
                                                           Airflow DAG (daily) ──► gold_user_activity
```

---

## Components Deployed

| Component | Kind | Namespace | Details |
|---|---|---|---|
| Altinity ClickHouse Operator | Deployment | kube-system | v0.24.x — manages ClickHouseInstallation CRs |
| ClickHouse cluster | ClickHouseInstallation | database | 1 shard / 1 replica, image `clickhouse/clickhouse-server:23.8` |
| Apache Airflow | Helm release `airflow` | airflow | Airflow 3.1.7, LocalExecutor, bundled PostgreSQL |

---

## ClickHouse Schema

All tables reside in the `default` database.

### Bronze Layer (Kafka Engine)

| Table | Topic | Purpose |
|---|---|---|
| `users_queue` | `postgres.public.users` | Reads Debezium CDC envelopes from Kafka; `before`/`after` columns hold raw JSON |
| `events_queue` | `mongo.commerce.events` | Reads Debezium MongoDB CDC events; `after` holds the full document JSON |

Key settings on both Kafka engine tables:
- `kafka_format = 'JSONEachRow'`
- `kafka_group_name = 'ch_users_consumer'` / `ch_events_consumer`

> **Offset note**: consumer group offsets were pre-reset to `earliest` via `kafka-consumer-groups.sh` before the Materialized Views were created, ensuring the initial snapshot data was fully consumed.

### Silver Layer

| Table | Engine | Details |
|---|---|---|
| `users_silver` | `ReplacingMergeTree(_version)` | Deduplicates by `user_id`. Query with `FINAL` to get latest state. `is_deleted=1` for CDC deletes. `_version = ts_ms`. |
| `events_silver` | `MergeTree()` | Append-only event store ordered by `(user_id, timestamp)`. |

### Materialized Views (Bronze → Silver)

`mv_users` — transforms Debezium PostgreSQL envelope:
- Extracts `user_id` from `after` (or `before` for delete events)
- Parses `updated_at` from microseconds since epoch: `toDateTime(updated_at_micros / 1000000)`
- Sets `is_deleted = 1` when `op = 'd'`

`mv_events` — transforms Debezium MongoDB envelope:
- `after` contains the full document as a JSON string
- `ts` field is a MongoDB Extended JSON Date: `{"$date": <epoch_ms>}` — extracted with `JSONExtract(JSONExtractRaw(after, 'ts'), '$date', 'Int64') / 1000`
- `metadata` is a nested JSON object stored as a raw JSON string via `JSONExtractRaw()`

### Gold Layer

| Table | Engine | Details |
|---|---|---|
| `gold_user_activity` | `ReplacingMergeTree(_updated_at)` | Daily aggregation of events per user per event type. Re-runs are idempotent — query with `FINAL` to deduplicate. |

Schema:
```sql
CREATE TABLE gold_user_activity (
    date        Date,
    user_id     Int32,
    full_name   String,
    email       String,
    event_type  String,
    event_count UInt64,
    _updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_updated_at)
ORDER BY (date, user_id, event_type);
```

---

## Airflow DAG: `gold_user_activity`

**File**: `dags/gold_user_activity.py`

| Property | Value |
|---|---|
| Schedule | `@daily` (midnight UTC) |
| Start date | 2026-02-18 |
| Catchup | Disabled |
| Task | `compute_gold_user_activity` (PythonOperator) |
| Retries | 2 (5-minute delay) |

### What the DAG does

For the logical execution date `ds`, the task runs this ClickHouse query:

```sql
INSERT INTO gold_user_activity (date, user_id, full_name, email, event_type, event_count)
SELECT
    toDate(e.timestamp)        AS date,
    u.user_id,
    anyLast(u.full_name)       AS full_name,
    anyLast(u.email)           AS email,
    e.event_type,
    count()                    AS event_count
FROM events_silver AS e
INNER JOIN (
    SELECT user_id, full_name, email
    FROM   users_silver FINAL
    WHERE  is_deleted = 0
) AS u ON e.user_id = u.user_id
WHERE toDate(e.timestamp) = toDate('<ds>')
GROUP BY date, u.user_id, e.event_type;
```

**Why it's idempotent**: ClickHouse `ReplacingMergeTree` keeps the row with the highest `_updated_at` per `(date, user_id, event_type)`. Each re-run inserts fresh rows with `_updated_at = now()`, which supersede previous rows. Querying with `SELECT ... FROM gold_user_activity FINAL` always returns the most recent version.

### ClickHouse Connection

The DAG connects via the ClickHouse HTTP interface (port 8123) using the `requests` library — no extra pip packages needed.

```python
CLICKHOUSE_URL  = "http://chi-chi-clickhouse-my-cluster-0-0.database.svc.cluster.local:8123/"
CLICKHOUSE_AUTH = {"user": "airflow", "password": "airflow123"}
```

The `airflow` ClickHouse user was created with `HOST ANY` to allow cross-namespace access from the `airflow` Kubernetes namespace. It is defined in `infrastructure/clickhouse.yaml` under `configuration.users` and injected via `configuration.files.users.d/zzz-airflow-access.xml` (which overrides the operator-generated network restrictions with `<networks replace="1">`).

---

## Key Issues and Fixes

### 1. `kafka_offset_reset_policy` does not exist in ClickHouse 23.8

The setting was renamed / introduced in later ClickHouse versions. For 23.8, consumer group offsets must be pre-reset on the Kafka broker before creating Materialized Views:

```bash
kubectl exec -n kafka my-cluster-my-pool-0 -- bash -c \
  '/opt/kafka/bin/kafka-consumer-groups.sh \
   --bootstrap-server localhost:9092 \
   --group ch_users_consumer \
   --reset-offsets --topic postgres.public.users --to-earliest --execute'
```

### 2. ConfigMap volume mount causes Airflow "recursive loop" error

Mounting an entire ConfigMap directory creates Kubernetes symlinks (`..XXXX` hidden directories) that Airflow's file walker treats as recursive loops. Fix: use `subPath` to mount each file individually — this bypasses the symlink structure and mounts the file directly.

```yaml
extraVolumeMounts:
  - name: dag-files
    mountPath: /opt/airflow/dags/gold_user_activity.py
    subPath: gold_user_activity.py
```

### 3. Altinity operator overrides user network config

The Altinity operator automatically adds a `host_regexp` and specific IPs to every user's `<networks>` section. The `ip: "::/0"` in the CHI YAML is ignored.

Fix: inject a separate XML file that uses `replace="1"` on `<networks>` to override the operator-generated restrictions. This is done via `configuration.files` in the CHI YAML, naming the file with a `zzz-` prefix so it is processed after the operator's `chop-generated-users.xml`.

### 4. MongoDB `after` field uses Extended JSON for Date types

MongoDB BSON Date fields are serialized by the Debezium MongoDB connector as Extended JSON: `{"$date": <epoch_ms>}`. The field name in the seeded data is `ts` (not `timestamp`).

Correct ClickHouse extraction:
```sql
toDateTime(JSONExtract(JSONExtractRaw(after, 'ts'), '$date', 'Int64') / 1000)
```

### 5. `airflow.operators.python` is deprecated in Airflow 3.x

Import from `airflow.providers.standard.operators.python` instead:
```python
from airflow.providers.standard.operators.python import PythonOperator
```

---

## Deployment Steps

```bash
# 1. Install Altinity ClickHouse operator
kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-bundle.yaml

# 2. Deploy ClickHouse cluster
kubectl apply -f infrastructure/clickhouse.yaml

# 3. Wait for pod to be ready
kubectl wait pod -n database -l clickhouse.altinity.com/chi=chi-clickhouse --for=condition=Ready --timeout=120s

# 4. Pre-reset consumer group offsets (before creating Kafka engine tables)
kubectl exec -n kafka my-cluster-my-pool-0 -- bash -c \
  '/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
   --group ch_users_consumer --reset-offsets --topic postgres.public.users \
   --to-earliest --execute'

kubectl exec -n kafka my-cluster-my-pool-0 -- bash -c \
  '/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
   --group ch_events_consumer --reset-offsets --topic mongo.commerce.events \
   --to-earliest --execute'

# 5. Create Bronze + Silver schema
kubectl exec -i -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" --multiquery \
  < scripts/create_tables.sql

# 6. Create Gold table
kubectl exec -i -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" --multiquery \
  < scripts/create_gold.sql

# 7. Deploy Airflow
kubectl create namespace airflow
kubectl create configmap airflow-dags -n airflow --from-file=dags/gold_user_activity.py
helm install airflow apache-airflow/airflow \
  --namespace airflow \
  --values infrastructure/airflow-values.yaml \
  --timeout 10m
```

---

## Verification

```bash
# Silver table counts
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT count() FROM users_silver"   # → 4

kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT count() FROM events_silver"  # → 5

# Deduplicated users
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT user_id, full_name, email FROM users_silver FINAL ORDER BY user_id"

# Gold layer (after DAG run)
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user default --password "" \
  --query "SELECT date, user_id, full_name, event_type, event_count
           FROM gold_user_activity FINAL
           ORDER BY user_id, event_type"

# Expected gold output:
# 2026-02-19  1  Alice Smith    login       1
# 2026-02-19  1  Alice Smith    view_item   1
# 2026-02-19  2  Bob A. Jones   add_to_cart 1
# 2026-02-19  2  Bob A. Jones   login       1
# 2026-02-19  3  Charlie Brown  login       1

# DAG status via Airflow CLI
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'airflow dags list 2>/dev/null'

# Test a DAG run
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'airflow dags test gold_user_activity 2026-02-19 2>/dev/null | tail -5'
```
