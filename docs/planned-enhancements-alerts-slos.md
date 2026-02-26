# CDC Pipeline — Alerts, SLOs & Observability

> Grafana Alert Rules + SLO Definitions for the CDC Pipeline

| Field | Value |
|-------|-------|
| **Date** | February 2026 |
| **Project** | CDC Pipeline — Kind/K8s (Debezium → Kafka → ClickHouse) |
| **Dashboard** | `http://localhost:3000/d/cdc-pipeline-v1/cdc-pipeline-overview` |
| **Alert rules** | `http://localhost:3000/alerting/list` |
| **Provisioned via** | `infrastructure/grafana-values.yaml` → `alerting.rules.yaml` |

## Context

The Grafana dashboard (CDC Pipeline Overview) provides 5 panels with 30-second auto-refresh and a native ClickHouse datasource. Two **provisioned alert rules** detect the two most critical silent failure modes: **data flow stopping** and the **gold layer going stale**.

The gold layer is managed by **dbt** (dbt-core 1.11.6 + dbt-clickhouse 1.10.0), baked into a custom Airflow image. The Airflow DAG runs two sequential BashOperator tasks: `dbt run` (incremental model build) → `dbt test` (6 `not_null` assertions). A dbt failure is silent from Grafana's perspective — the gold table simply stops refreshing, which Alert 2 detects.

Alert rules are deployed via Grafana's Unified Alerting file-based provisioning in `grafana-values.yaml`. On the Kind cluster, alerts are visible in the Grafana Alerting UI (`/alerting/list`) but no emails are sent (no SMTP configured). In production, alerts would route to PagerDuty / Slack via contact points.

---

## Alert 1 — Throughput Flatline (Critical)

### What It Detects

The events-per-minute time series drops to zero for 2 or more consecutive minutes. This indicates one of three failure modes:

1. The Debezium connector has crashed and stopped reading the oplog/WAL
2. The Kafka consumer group has stalled and is not polling new messages
3. The ClickHouse Materialized View has stopped writing to `events_silver`

This is the most critical alert. Data stops flowing silently — no errors are thrown, no pods crash — and without this alert you would only discover the problem when someone queries stale data downstream.

### Implementation — Deployed

| Parameter | Value |
|-----------|-------|
| **Alert UID** | `alert-throughput-flatline` |
| **Rule group** | `cdc-throughput-alerts` (folder: CDC Pipeline) |
| **Condition** | `last()` of query A IS BELOW 1 |
| **Evaluate every** | 1 minute |
| **Pending period (`for`)** | 2 minutes (must be below threshold for 2 consecutive evaluations) |
| **Severity label** | `critical` |
| **Query A** | `SELECT count() AS value FROM events_silver WHERE _ingested_at >= now() - INTERVAL 1 MINUTE` |
| **Threshold** | Grafana `__expr__` evaluator: `lt 1` on query A result |
| **Provisioned in** | `infrastructure/grafana-values.yaml` → `alerting.rules.yaml` |

### Why the 2-Minute Threshold

The pipeline's polling floor is ~2 seconds (Debezium 500ms + ClickHouse 500ms + measurement overhead). In a genuinely active system, `events_silver` should receive writes every few seconds under any meaningful load. A 2-minute window is long enough to avoid false positives during intentional idle periods, but short enough to catch a real connector failure before downstream consumers notice stale data.

### Improvement: Partial Degradation Detection

> **Note**: This alert only fires when throughput drops to **zero**. It does not catch partial degradation — for example, throughput dropping from 1,000/min to 5/min would not trigger this alert. In production, add a second alert using anomaly detection or a percentage-drop-from-baseline condition (e.g., throughput drops below 20% of the trailing 1-hour average).

### First Response Checklist

- `kubectl get pods -n database -n kafka` — check for CrashLoopBackOff
- `kubectl describe kafkaconnector postgres-connector -n kafka` — check READY status
- `kubectl logs -n kafka deployment/kafka-connect` — look for ERROR lines
- Check ClickHouse: `SELECT count() FROM events_silver` — compare to expected

---

## Alert 2 — Gold Layer Staleness (High)

### What It Detects

The `gold_user_activity` table has not been updated in more than 25 hours. Since the Airflow DAG runs daily, a 25-hour threshold catches a missed run while allowing a 1-hour buffer for DAG execution time and scheduling jitter.

This alert catches a silent Airflow DAG or dbt failure. Unlike a connector crash (which may produce errors), a failed dbt run often leaves no visible signal in Grafana — the gold layer simply stops refreshing. Business users querying aggregated user activity would see stale numbers with no warning. Since dbt is now triggered by Airflow's `gold_user_activity` DAG (via BashOperator), both DAG scheduling failures and dbt model failures are caught by this alert.

### Implementation — Deployed

| Parameter | Value |
|-----------|-------|
| **Alert UID** | `alert-gold-staleness` |
| **Rule group** | `cdc-freshness-alerts` (folder: CDC Pipeline) |
| **Condition** | `last()` of query A IS ABOVE 25 |
| **Evaluate every** | 30 minutes |
| **Pending period (`for`)** | 0s (fire immediately when threshold crossed) |
| **Severity label** | `high` |
| **Query A** | `SELECT dateDiff('hour', max(last_event_at), now()) AS value FROM gold_user_activity FINAL` |
| **Threshold** | Grafana `__expr__` evaluator: `gt 25` on query A result |
| **Provisioned in** | `infrastructure/grafana-values.yaml` → `alerting.rules.yaml` |

### Why the 25-Hour Threshold

The Airflow DAG `gold_user_activity` runs once per day. A 24-hour threshold would fire every day before the DAG runs, producing false positives. Adding a 1-hour buffer (25 hours) gives the DAG time to execute and accounts for scheduling jitter in a local Kind cluster where Airflow competes for CPU with other services.

### First Response Checklist

- `kubectl get pods -n airflow` — check scheduler and dag-processor pods
- Airflow UI: `http://localhost:8080` — check `gold_user_activity` DAG run history
- Run dbt manually to test: `kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- bash -c 'cd /opt/airflow/dbt && dbt run --select gold_user_activity'`
- Run dbt debug to check connection: `kubectl exec -n airflow airflow-scheduler-0 -c scheduler -- bash -c 'cd /opt/airflow/dbt && dbt debug'`
- Check ClickHouse: `SELECT max(last_event_at) FROM gold_user_activity FINAL` — confirm staleness

---

## Notification Channels

**Current state (Kind cluster)**: Both alerts are provisioned and evaluating. Alert state transitions (Normal → Pending → Firing → Resolved) are visible in the Grafana Alerting UI at `/alerting/list`. No external notifications are sent — no SMTP or webhook is configured. This is sufficient for a development environment.

**Production routing**: In production, add contact points to `grafana-values.yaml` to route alerts externally:

| Severity | Channel | Routing |
|----------|---------|---------|
| **Critical** | PagerDuty / on-call rotation | Immediate page — data loss in progress |
| **High** | Slack `#data-alerts` + email | Investigate within 1 hour |
| **Warning** | Slack `#data-alerts` | Review during business hours |

On cloud infrastructure, integrate with the organization's existing incident management tooling. Grafana supports PagerDuty, Slack, OpsGenie, webhook, and email contact points natively.

---

## Interview Framing

When asked about monitoring in interviews:

> *"I have two provisioned Grafana alert rules deployed via Helm values. The first is a throughput flatline detector — it queries events_silver every minute and fires after 2 minutes of zero ingest, catching silent connector crashes. The second is a gold layer staleness alert — it checks the age of gold_user_activity every 30 minutes and fires if the table hasn't been refreshed in 25 hours, catching failed Airflow DAG runs or dbt errors. Both are provisioned as code in grafana-values.yaml, so they survive pod restarts. The one gap is Kafka consumer lag — that requires exposing JMX metrics, which on AWS MSK is a built-in CloudWatch metric, no exporter needed."*

When asked about the transformation layer:

> *"dbt manages the silver → gold transformation. It's baked into a custom Airflow image and triggered by a DAG with two tasks: `dbt run` builds the incremental gold model, then `dbt test` runs not_null assertions as a data quality gate. In production, I'd replace the BashOperator with a KubernetesPodOperator running a dedicated dbt image — this isolates dbt dependencies and allows model updates without rebuilding the Airflow image."*

---

## Service Level Objectives (SLOs)

These three SLOs define the production commitments for the CDC pipeline. Each threshold is derived directly from stress test results — not aspirational targets.

### SLO 1 — Silver Layer Latency (Critical)

| Parameter | Value |
|-----------|-------|
| **Commitment** | **99% of database events reach ClickHouse silver layer in < 10 seconds** |
| **Evidence** | Stress test wave 8 (25,000 rows) showed 6s max latency for PostgreSQL, 4s for MongoDB. 10 seconds provides a mathematically backed safety buffer above the worst observed case. |
| **Measured by** | Grafana CDC Throughput — Events/min panel (tracks `_ingested_at` timestamps in `events_silver`) |
| **Breach indicator** | Throughput Flatline alert fires (< 1 event/min for 2 min) — enforced by Alert 1 |
| **Error budget** | 1% of events may exceed 10s — ~14.4 minutes of breach time allowed per day |

### SLO 2 — Kafka Consumer Lag (High)

| Parameter | Value |
|-----------|-------|
| **Commitment** | **Kafka consumer lag remains < 5,000 messages 99% of the time** |
| **Evidence** | Sustained throughput of ~6,250 rows/sec (MongoDB) and ~4,166 rows/sec (PostgreSQL). At 5,000 messages, a healthy consumer clears the lag in under 1 second. |
| **Measured by** | `kafka-consumer-groups.sh --describe` or Kafka JMX `kafka.consumer:type=consumer-fetch-manager-metrics` (`records-lag-max`) |
| **Breach indicator** | Sustained lag > 5,000 for more than 30 seconds — add as Alert 3 once Kafka metrics are exposed |

> **Implementation note**: Kafka metrics are not currently exposed to Grafana in the Kind cluster. This requires adding Kafka Exporter or enabling Strimzi's built-in Prometheus metrics. **Production alternative**: On managed Kafka (AWS MSK), consumer lag is a built-in CloudWatch metric (`SumOffsetLag`) — no exporter deployment needed. This is the recommended path for production and eliminates the Prometheus dependency entirely.

### SLO 3 — Gold Layer Freshness (High)

| Parameter | Value |
|-----------|-------|
| **Commitment** | **Gold tables reflect data no older than 25 hours, 99.9% of the time** |
| **Evidence** | The `gold_user_activity` Airflow DAG runs once per day. It executes `dbt run` (~1.3s for the incremental model) followed by `dbt test` (~20s for 6 `not_null` assertions). 25 hours = 24-hour schedule + 1-hour execution buffer for CPU contention on a shared Kind node. dbt execution time (~22s total) is negligible relative to the 1-hour buffer. |
| **Measured by** | `SELECT dateDiff('hour', max(last_event_at), now()) AS staleness_hours FROM gold_user_activity FINAL` |
| **Breach indicator** | Gold Layer Staleness alert fires (`staleness_hours > 25`) — enforced by Alert 2 |
| **Error budget** | 0.1% violation allowed — ~8.76 hours per year of gold layer staleness beyond 25 hours |
| **Correction** | *Original threshold was stated as 15 minutes — this is incorrect. The DAG runs daily, so a 15-minute SLO would breach 23+ hours per day. Corrected to 25 hours throughout this document.* |

---

## Enforcement Mechanism

Three layers of enforcement work together to prevent and recover from SLO breaches:

- **Layer 1 — Reactive alerting (deployed)**: Alert 1 (Throughput Flatline, `alert-throughput-flatline`) enforces SLO 1. Alert 2 (Gold Layer Staleness, `alert-gold-staleness`) enforces SLO 3. Both are provisioned in `grafana-values.yaml`. SLO 2 requires a third alert once Kafka metrics are exposed to Grafana.
- **Layer 1.5 — dbt test as data quality gate**: The `dbt_test` task runs 6 `not_null` assertions on the gold table after every `dbt_run`. If any assertion fails, the Airflow task fails and the DAG is marked as failed — providing an early signal before the staleness alert threshold is reached. This catches data quality issues (e.g., null user_id from a broken CDC schema change) that would otherwise only surface when downstream consumers query bad data.
- **Layer 2 — Automatic recovery**: Kubernetes restarts crashed pods. Strimzi reconciles failed KafkaConnector CRs back to RUNNING state. Airflow retries failed DAG tasks (2 retries, 5-minute delay). Most failure modes self-heal without manual intervention, limiting breach duration.
- **Layer 3 — Error budget tracking (production)**: Track consumption of the 1% / 0.1% error budgets weekly. If budget burns faster than expected, freeze deployments and investigate root cause before the budget is exhausted. This follows Google SRE methodology — not yet implemented on Kind cluster.

---

## Summary — Alerts & SLO Status

| Item | Type | Detects | Threshold | Status | Priority |
|------|------|---------|-----------|--------|----------|
| Alert 1: Throughput Flatline | Grafana Alert | Connector crash / Kafka stall | < 1 event/min for 2 min | **Implemented** | **Critical** |
| Alert 2: Gold Layer Staleness | Grafana Alert | Airflow DAG missed / dbt run or test failed | staleness > 25 hours | **Implemented** | **High** |
| SLO 1: Silver Latency | SLO | Event ingestion delay | < 10 seconds (99th pct) | **Tracking** (Alert 1) | **Critical** |
| SLO 2: Kafka Lag | SLO | Consumer lag buildup | < 5,000 messages | Needs Kafka metrics exposed | **High** |
| SLO 3: Gold Freshness | SLO | Gold data staleness | < 25 hours (99.9th pct) | **Tracking** (Alert 2) | **High** |
