# Phase 4b: dbt Integration — Silver → Gold Transformation

## Objective

Replace the raw SQL `PythonOperator` in the Airflow DAG with **dbt** (data build tool) as the transformation layer between the Silver and Gold ClickHouse tables. dbt provides:

1. **Modular SQL models** with dependency management (`ref()`, `source()`)
2. **Schema tests** (`not_null`) as a built-in data quality gate
3. **Incremental materialization** that avoids full-table rebuilds on each run
4. **Documentation-as-code** via `schema.yml` files co-located with models

---

## Architecture

```
Silver Layer (CDC-populated)                          dbt (inside Airflow pod)
┌──────────────────────────────┐                     ┌──────────────────────────────────┐
│  users_silver                │ ──── source() ────► │  stg_users.sql (ephemeral)       │
│  (ReplacingMergeTree)        │                     │    SELECT ... FROM FINAL          │
│                              │                     │    WHERE is_deleted = 0            │
├──────────────────────────────┤                     ├──────────────────────────────────┤
│  events_silver               │ ──── source() ────► │  stg_events.sql (ephemeral)      │
│  (MergeTree, append-only)    │                     │    SELECT ... FROM events_silver   │
└──────────────────────────────┘                     └───────────────┬──────────────────┘
                                                                    │ ref()
                                                                    ▼
                                                     ┌──────────────────────────────────┐
                                                     │  gold_user_activity.sql           │
                                                     │  (incremental, append strategy)   │
                                                     │  ReplacingMergeTree(_updated_at)  │
                                                     │  ORDER BY (date, user_id)         │
                                                     └───────────────┬──────────────────┘
                                                                    │
                                                                    ▼
                                                     ┌──────────────────────────────────┐
                                                     │  gold_user_activity table         │
                                                     │  Query with FINAL for dedup       │
                                                     └──────────────────────────────────┘
```

Staging models are **ephemeral** — they compile as CTEs inside the gold query. No intermediate tables are created.

---

## What Changed from Phase 4

| Before (Phase 4) | After (Phase 4b) |
|---|---|
| `PythonOperator` calling ClickHouse HTTP API with raw SQL via `requests` | `BashOperator` chain: `dbt run` → `dbt test` |
| SQL embedded in Python DAG file | SQL in versioned `.sql` model files with Jinja templating |
| No schema tests or data quality checks | `not_null` tests on all key columns (6 tests) |
| `apache/airflow:3.0.2` stock image | Custom `airflow-dbt:1.0` image with dbt-core + dbt-clickhouse baked in |
| Credentials hardcoded in DAG | Environment variables (`DBT_CH_HOST`, `DBT_CH_USER`, `DBT_CH_PASSWORD`) injected via Helm |

---

## Key Files

| File | Purpose |
|---|---|
| `dbt/dbt_project.yml` | Project config — name, profile, materialization defaults |
| `dbt/profiles.yml` | ClickHouse connection — uses `env_var()` with localhost defaults |
| `dbt/.env.example` | Template for local development environment variables |
| `dbt/packages.yml` | External dbt packages (currently empty) |
| `dbt/models/staging/stg_users.sql` | Ephemeral model — deduplicated active users from `users_silver FINAL` |
| `dbt/models/staging/stg_events.sql` | Ephemeral model — all events from `events_silver` |
| `dbt/models/staging/schema.yml` | Source definitions + staging model docs and `not_null` tests |
| `dbt/models/gold/gold_user_activity.sql` | Incremental gold model — daily per-user activity summary |
| `dbt/models/gold/schema.yml` | Gold model docs and `not_null` tests (6 columns) |
| `infrastructure/Dockerfile.airflow-dbt` | Custom Airflow image with dbt pre-installed |
| `infrastructure/airflow-values.yaml` | Helm values — custom image, env vars, resource limits |
| `dags/gold_user_activity.py` | Airflow DAG — BashOperator chain (`dbt_run` → `dbt_test`) |

---

## dbt Project Structure

```
dbt/
├── dbt_project.yml          # name: cdc_pipeline, profile: cdc_pipeline
├── profiles.yml             # ClickHouse connection via env_var() with defaults
├── .env.example             # DBT_CH_HOST=localhost, DBT_CH_USER=airflow, ...
├── packages.yml             # packages: [] (no external packages)
├── models/
│   ├── staging/
│   │   ├── stg_users.sql    # SELECT ... FROM users_silver FINAL WHERE is_deleted = 0
│   │   ├── stg_events.sql   # SELECT ... FROM events_silver
│   │   └── schema.yml       # Sources (silver layer) + staging model tests
│   └── gold/
│       ├── gold_user_activity.sql  # JOIN stg_users + stg_events, GROUP BY (date, user_id)
│       └── schema.yml              # Gold model column docs + not_null tests
├── macros/                  # Reserved (empty)
├── tests/                   # Reserved (empty)
├── target/                  # Build artifacts (gitignored)
├── dbt_packages/            # Installed packages (gitignored)
└── logs/                    # Run logs (gitignored)
```

---

## Materialization Strategy

### Staging Models — Ephemeral

```yaml
# dbt_project.yml
models:
  cdc_pipeline:
    staging:
      +materialized: ephemeral
```

Ephemeral models compile as **CTEs** inside the downstream gold query. No physical tables are created in ClickHouse. This avoids unnecessary intermediate storage while still giving us modular, testable SQL.

- **`stg_users`**: Reads `users_silver` with `FINAL` to deduplicate ReplacingMergeTree rows. Filters out soft-deleted users (`is_deleted = 0`).
- **`stg_events`**: Reads `events_silver` directly — append-only table, no deduplication needed.

### Gold Model — Incremental Append on ReplacingMergeTree

```sql
{{
    config(
        materialized='incremental',
        incremental_strategy='append',
        engine='ReplacingMergeTree(_updated_at)',
        order_by='(date, user_id)',
        unique_key='(date, user_id)'
    )
}}
```

| Config | Value | Why |
|---|---|---|
| `materialized` | `incremental` | Avoids full-table rebuild on each run |
| `incremental_strategy` | `append` | New rows are INSERTed; FINAL deduplicates at query time |
| `engine` | `ReplacingMergeTree(_updated_at)` | Version column ensures latest row wins on merge |
| `order_by` | `(date, user_id)` | Deduplication key — one row per user per day |
| `unique_key` | `(date, user_id)` | Tells dbt what constitutes a duplicate |

**How idempotency works**: Re-running `dbt run` for the same date inserts rows with a newer `_updated_at` timestamp. When queried with `FINAL`, ClickHouse returns only the row with the highest `_updated_at` per `(date, user_id)` — effectively an upsert without DELETE.

**Incremental filter**: On subsequent runs, only events where `toDate(e.timestamp) >= max(date)` from the existing table are processed. The first run (`--full-refresh`) processes all data.

---

## ClickHouse Connection

### Local Development (port-forward)

```
Developer machine → localhost:8123 → Kind port mapping → ClickHouse pod
```

dbt `profiles.yml` defaults to `localhost` when env vars are not set:

```yaml
host: "{{ env_var('DBT_CH_HOST', 'localhost') }}"
port: 8123
user: "{{ env_var('DBT_CH_USER', 'airflow') }}"
password: "{{ env_var('DBT_CH_PASSWORD', 'airflow123') }}"
```

### Inside the Airflow Pod (Kubernetes DNS)

Helm values inject environment variables that override the defaults:

| Env Var | Value |
|---|---|
| `DBT_CH_HOST` | `chi-chi-clickhouse-my-cluster-0-0.database.svc.cluster.local` |
| `DBT_CH_USER` | `airflow` |
| `DBT_CH_PASSWORD` | `airflow123` |

The `airflow` user was created in Phase 4 with network access from all namespaces (via `zzz-airflow-access.xml` override in the ClickHouse CHI spec).

---

## Custom Airflow Image

The stock `apache/airflow:3.0.2` image does not include dbt. A custom image bakes in both dbt and the project files:

```dockerfile
FROM apache/airflow:3.0.2

USER root
RUN mkdir -p /opt/airflow/dbt
COPY dbt/ /opt/airflow/dbt/
RUN chown -R airflow:root /opt/airflow/dbt

USER airflow
RUN pip install --no-cache-dir --retries 5 --timeout 120 dbt-core==1.11.6 dbt-clickhouse==1.10.0
```

**Build and load into Kind**:

```bash
docker build -t airflow-dbt:1.0 -f infrastructure/Dockerfile.airflow-dbt .
kind load docker-image airflow-dbt:1.0 --name data-engineering-challenge
```

The Helm values reference the custom image:

```yaml
defaultAirflowRepository: airflow-dbt
defaultAirflowTag: "1.0"
```

**Pinned versions**: `dbt-core==1.11.6` and `dbt-clickhouse==1.10.0` are pinned to avoid breaking changes from the community-maintained ClickHouse adapter.

---

## Airflow DAG

The DAG uses two sequential `BashOperator` tasks:

```python
dbt_run = BashOperator(
    task_id="dbt_run",
    bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --select gold_user_activity",
)

dbt_test = BashOperator(
    task_id="dbt_test",
    bash_command=f"cd {DBT_PROJECT_DIR} && dbt test --select gold_user_activity",
)

dbt_run >> dbt_test
```

| Property | Value |
|---|---|
| DAG ID | `gold_user_activity` |
| Schedule | `@daily` (midnight UTC) |
| Start date | 2026-02-18 |
| Catchup | False |
| Retries | 2 (5-minute delay) |
| Tags | `gold`, `clickhouse`, `dbt`, `phase4` |
| Task chain | `dbt_run` → `dbt_test` |

**Why BashOperator, not KubernetesPodOperator**: On the Kind cluster, dbt is baked into the Airflow image at `/opt/airflow/dbt/`. BashOperator runs dbt directly — no sidecar pod, no image pull, no network overhead. In production, `KubernetesPodOperator` with a dedicated dbt Docker image would isolate dbt dependencies and allow model updates without rebuilding the Airflow image.

---

## Schema Tests

dbt runs 6 `not_null` tests on the gold model after each transformation:

| Column | Test | Why |
|---|---|---|
| `date` | `not_null` | Every row must have a calendar date |
| `user_id` | `not_null` | Every row must reference a user |
| `full_name` | `not_null` | User name must propagate from silver layer |
| `email` | `not_null` | User email must propagate from silver layer |
| `total_events` | `not_null` | COUNT() always returns a value |
| `last_event_at` | `not_null` | MAX(timestamp) always returns a value |

**Why no `unique` test**: ClickHouse `ReplacingMergeTree` does not enforce uniqueness at write time — it deduplicates on merge (background process) or when queried with `FINAL`. A dbt `unique` test on `(date, user_id)` would fail between merges. Using `not_null` tests only avoids false failures.

---

## Deployment Steps

```bash
# 1. Build custom Airflow image with dbt
docker build -t airflow-dbt:1.0 -f infrastructure/Dockerfile.airflow-dbt .

# 2. Load into Kind
kind load docker-image airflow-dbt:1.0 --name data-engineering-challenge

# 3. Update Airflow DAG ConfigMap
kubectl delete configmap airflow-dags -n airflow 2>/dev/null
kubectl create configmap airflow-dags --from-file=dags/ -n airflow

# 4. Upgrade Airflow Helm release (picks up new image + env vars)
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  --values infrastructure/airflow-values.yaml \
  --timeout 10m

# 5. Wait for scheduler to be ready
kubectl rollout status deployment/airflow-scheduler -n airflow --timeout=120s

# 6. Drop old gold table (dbt will recreate it)
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user airflow --password airflow123 \
  --query "DROP TABLE IF EXISTS gold_user_activity"

# 7. First run (full refresh)
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'cd /opt/airflow/dbt && dbt run --full-refresh --select gold_user_activity'

# 8. Run tests
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'cd /opt/airflow/dbt && dbt test --select gold_user_activity'

# 9. Verify gold table
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user airflow --password airflow123 \
  --query "SELECT * FROM gold_user_activity FINAL ORDER BY date, user_id LIMIT 10"
```

---

## Verification

### dbt connection

```bash
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'cd /opt/airflow/dbt && dbt debug'
# Should show: Connection test: OK
```

### dbt run

```bash
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'cd /opt/airflow/dbt && dbt run --select gold_user_activity'
# Should show: PASS=1 (1 model completed)
```

### dbt test

```bash
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'cd /opt/airflow/dbt && dbt test --select gold_user_activity'
# Should show: PASS=6 (6 not_null tests)
```

### Full DAG test (Airflow orchestration)

```bash
kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- \
  bash -c 'airflow dags test gold_user_activity 2026-02-27 2>/dev/null'
# Runs dbt_run → dbt_test as a complete DAG execution
```

### Gold table query

```bash
kubectl exec -n database chi-chi-clickhouse-my-cluster-0-0-0 -- \
  clickhouse-client --user airflow --password airflow123 \
  --query "SELECT date, user_id, full_name, total_events, last_event_at FROM gold_user_activity FINAL ORDER BY total_events DESC LIMIT 5"
```

---

## Running dbt Locally

For development and testing without the Airflow pod:

```bash
# 1. Install dbt
pip install dbt-core==1.11.6 dbt-clickhouse==1.10.0

# 2. Port-forward ClickHouse
kubectl port-forward -n database svc/clickhouse-chi-clickhouse 8123:8123

# 3. Run dbt (profiles.yml defaults to localhost:8123)
cd dbt
dbt debug           # Test connection
dbt run             # Build gold table
dbt test            # Run schema tests
dbt run --full-refresh  # Rebuild from scratch
```

No `.env` file is needed — `profiles.yml` defaults to `localhost` / `airflow` / `airflow123` when environment variables are not set.

---

## Design Decisions

### Why ephemeral staging models (not views or tables)?

Ephemeral models add zero storage overhead and zero query latency — they compile directly into the gold model's SQL as CTEs. Since the staging models are only referenced by one downstream model (`gold_user_activity`), physical materialization would be waste.

### Why `append` strategy instead of `delete+insert`?

ClickHouse does not support efficient single-row DELETEs. The `delete+insert` strategy (used by some dbt adapters) would create lightweight deletes that degrade read performance. Append + `ReplacingMergeTree` + `FINAL` achieves the same idempotent behavior with better performance.

### Why bake dbt into the Airflow image?

On a Kind cluster with limited resources, running dbt as a separate Kubernetes pod (via `KubernetesPodOperator`) adds scheduling latency, image pull overhead, and an extra pod competing for CPU. Baking dbt into the Airflow image eliminates all of this. The tradeoff is that dbt model changes require an image rebuild — acceptable for a development environment.

### Why not use `unique` tests?

See [Schema Tests](#schema-tests) above. `ReplacingMergeTree` deduplication is eventually consistent — `unique` tests would produce false failures between background merges.

---

## Production Approach

In production, replace the `BashOperator` with `KubernetesPodOperator`:

```python
# Production pattern (not implemented on Kind)
from airflow.providers.cncf.kubernetes.operators.kubernetes_pod import KubernetesPodOperator

dbt_run = KubernetesPodOperator(
    task_id="dbt_run",
    image="your-registry/dbt-clickhouse:1.0",
    cmds=["dbt"],
    arguments=["run", "--select", "gold_user_activity"],
    env_vars={"DBT_CH_HOST": "clickhouse.database.svc", ...},
)
```

This isolates dbt dependencies, allows model updates without rebuilding the Airflow image, and enables independent scaling of dbt execution resources.

---

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| `dbt debug` shows connection refused | ClickHouse pod not running or wrong host | Check `kubectl get pods -n database`. For local: ensure port-forward is active. For in-cluster: verify `DBT_CH_HOST` env var. |
| `dbt run` fails with "table already exists" | Existing table conflicts with dbt DDL | `DROP TABLE gold_user_activity` then `dbt run --full-refresh` |
| `dbt test` fails with `not_null` failure | Null data in silver layer (upstream CDC issue) | Check source tables: `SELECT * FROM users_silver FINAL WHERE full_name IS NULL` |
| DAG shows `dbt_run` failed | dbt not found in Airflow image | Verify custom image: `kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- dbt --version` |
| DAG shows `dbt_test` failed but `dbt_run` passed | Data quality issue in gold table | Run `dbt test` manually to see which column has nulls |
| Changes to dbt models not reflected | Old image cached in Kind | Rebuild with new tag: `airflow-dbt:1.1`, `kind load`, update Helm values |
