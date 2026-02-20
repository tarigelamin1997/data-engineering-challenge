# Phase 5: Stress Test — Methodology

## 1. Objective

Determine the **practical throughput limits** of our CDC pipeline running on a single-node Kind cluster. Specifically:

- What is the **baseline latency** for a single CDC event traversing the full pipeline?
- At what load does the system begin to **degrade** (latency increases but data still arrives)?
- At what load does the system **break** (broker restarts, connectors crash, data loss)?

---

## 2. What We Measure

### 2.1 End-to-End (e2e) Latency

The time elapsed from **row committed in the source database** to **row visible in the ClickHouse silver table**.

```
t_start ──► INSERT INTO postgres / mongo
                │
                ▼
            WAL / Oplog captured by Debezium
                │
                ▼
            Kafka topic (CDC event produced)
                │
                ▼
            ClickHouse Kafka Engine polls topic
                │
                ▼
            Materialized View writes to silver table
                │
                ▼
t_end ────► SELECT count() shows expected row count
```

**Formula**: `e2e_latency = t_end − t_start`

This is a **conservative upper bound** — it includes the polling intervals of both Debezium and ClickHouse, which add idle wait time on top of actual processing.

### 2.2 Throughput

Rows processed per second: `N_rows / e2e_latency`. This tells us the effective rate at which the pipeline can absorb and materialize changes.

### 2.3 System Health Indicators

At each wave, we also check:

| Indicator | How we check | Healthy | Degraded | Broken |
|-----------|-------------|---------|----------|--------|
| Kafka broker | Pod status + logs | 1/1 Running, no errors | "Slow controller event" warnings | Pod restart, CrashLoopBackOff |
| Debezium Connect | KafkaConnector CR status | READY=True | READY=True but high lag | READY=False, 500 errors |
| ClickHouse | Silver table count matches expected | Count matches within timeout | Count matches but slowly | Count never reaches expected |
| CPU pressure | `kubectl top nodes` | < 70% | 70–90% | > 90% sustained |

---

## 3. How Inputs Are Introduced

Each test wave inserts rows directly into the **source databases** — the same path that production changes would take. Debezium captures these via the PostgreSQL WAL and MongoDB oplog.

### PostgreSQL (users)

```sql
INSERT INTO users (full_name, email)
SELECT
    'StressUser_' || g  AS full_name,
    'stress_' || g || '@test.com' AS email
FROM generate_series(1, N) AS g;
```

A single `INSERT ... SELECT generate_series()` statement produces N rows atomically. PostgreSQL writes them to the WAL in one transaction, which Debezium reads as N individual change events.

### MongoDB (events)

```javascript
var docs = [];
for (var i = 0; i < N; i++) {
    docs.push({
        user_id: (i % num_users) + 1,
        event_type: "stress_test",
        ts: new Date(),
        metadata: { wave: wave_number, seq: i }
    });
}
db.events.insertMany(docs);
```

`insertMany()` writes N documents in a single batch. Each document generates one oplog entry, which Debezium captures individually.

### Measurement Flow

```
1. Record count_before = SELECT count() FROM silver_table
2. Record t_start = current time
3. Execute INSERT of N rows into source DB
4. Poll: SELECT count() FROM silver_table every 2 seconds
5. When count reaches count_before + N → record t_end
6. If 120 seconds pass without reaching target → mark as TIMEOUT
7. Collect system health indicators
8. Wait 30 seconds for system to stabilize before next wave
```

---

## 4. Test Point Selection

We do **not** use arbitrary round numbers. Each test point is chosen because it aligns with a known internal threshold in our pipeline components.

### 4.1 System Parameters That Define Thresholds

| Parameter | Default Value | Component | Why It Matters |
|-----------|--------------|-----------|---------------|
| `poll.interval.ms` | 500 ms | Debezium | How often Debezium polls the WAL. Rows arriving within one interval are batched together. |
| `max.batch.size` | 2048 | Debezium | Maximum rows Debezium reads per poll cycle. Beyond this, it needs multiple cycles. |
| `kafka_max_block_size` | 65536 | ClickHouse Kafka Engine | Max rows ClickHouse pulls from Kafka per poll. Not a bottleneck at our scale. |
| `kafka_poll_timeout_ms` | 500 ms | ClickHouse Kafka Engine | How long ClickHouse waits for new messages per poll. Defines minimum MV flush interval. |
| KRaft controller timeout | 5000 ms | Kafka broker (KRaft) | If the controller event loop takes > 5s, the broker is considered unresponsive. |
| Kind node resources | ~4 vCPU, ~8 GB RAM | Docker Desktop | Hard ceiling on available compute. All services share this. |

### 4.2 CPU Budget Analysis

All services run on a single Kind node. Here is the approximate CPU consumption:

```
Component               Idle (cores)    Burst (cores)
─────────────────────────────────────────────────────
KRaft controller          0.5             0.5        (constant — must never starve)
Kafka broker              0.5             1.5
Debezium Connect          0.5             1.5
ClickHouse server         0.3             1.0
PostgreSQL                0.2             0.5
MongoDB                   0.2             0.5
Strimzi operator          0.1             0.2
Altinity operator         0.1             0.1
Kubernetes system pods    0.3             0.5
─────────────────────────────────────────────────────
TOTAL                     2.7             6.3
Available                 ~4.0            ~4.0
Headroom                  1.3            -2.3    ← cannot sustain full burst
```

**Key insight**: The system has ~1.3 cores of headroom at idle. Under full burst, it would need 6.3 cores but only has 4. The constraint is **CPU**, not memory or disk. The breaking point occurs when sustained CPU demand exceeds 4 cores long enough for the KRaft controller to timeout (5 seconds).

### 4.3 The Test Points

| Wave | Rows (N) | Rationale | Expected Behavior |
|------|----------|-----------|-------------------|
| **1** | **1** | **Baseline**. Single row, minimum overhead. Measures the pipeline's floor latency: Debezium poll interval + Kafka produce + ClickHouse poll interval. | e2e ≈ 1–3s (sum of two 500ms poll intervals plus processing). Throughput metric not meaningful at N=1. |
| **2** | **10** | **Within single Debezium poll**. 10 rows fit easily within one `max.batch.size` (2048) and one Kafka produce batch. Tests whether batching adds measurable overhead. | e2e ≈ 1–3s. Same as baseline — all rows travel as one batch. |
| **3** | **100** | **Kafka producer batching boundary**. At ~100 rows, the Kafka producer's `batch.size` (default 16KB) may fill up, forcing a flush mid-batch. Tests serialization overhead. | e2e ≈ 2–5s. Slight increase from serialization of 100 Debezium envelopes (~150KB). |
| **4** | **500** | **ClickHouse MV flush test**. 500 rows arrive across 1–2 ClickHouse Kafka Engine poll cycles. Tests whether the Materialized View can keep up with sustained ingest. | e2e ≈ 3–8s. CPU starts climbing. May see first `kubectl top` pressure. |
| **5** | **2048** | **Debezium batch boundary**. Exactly the default `max.batch.size`. Debezium must complete one full batch cycle. The WAL reader, CDC event serializer, and Kafka producer all operate at their designed capacity. | e2e ≈ 5–15s. First meaningful stress. KRaft controller may log "slow event" if CPU > 90%. |
| **6** | **5000** | **Multi-batch sustained load**. 5000 / 2048 ≈ 2.5 Debezium batches. The broker must handle sustained writes while KRaft competes for CPU. This is where the CPU budget math predicts trouble: Debezium + broker burst = ~3.0 cores, leaving < 1 core for everything else. | e2e ≈ 10–30s. Expect KRaft "slow controller event" warnings. System recovers but slowly. |
| **7** | **10000** | **WAL pressure test**. A 10K-row INSERT generates ~3–5 MB of WAL data. Debezium needs ~5 poll cycles. Sustained CPU demand > 4 cores for 10+ seconds. KRaft controller timeout (5s) likely exceeded. | e2e ≈ 30–90s or TIMEOUT. Possible broker restart. If broker restarts, Connect enters CrashLoopBackOff. |
| **8** | **25000** | **Expected breaking point**. ~12 Debezium batches, ~10 MB WAL, sustained CPU > 4 cores for 30+ seconds. Multiple KRaft timeouts likely. ClickHouse Kafka engine may hit poll timeouts and re-balance consumer group. | TIMEOUT or cascade failure: broker restart → Connect crash → data stalls. |

### 4.4 Why These Numbers and Not Others

The progression is **not linear** (1, 10, 100, ...) nor arbitrary. Each point tests a specific component boundary:

- **Waves 1–2**: Establish baseline (below any batch boundary)
- **Wave 3**: Kafka producer batch.size boundary (~16KB ≈ 100 CDC envelopes)
- **Wave 4**: ClickHouse Kafka engine multi-poll threshold
- **Wave 5**: Debezium max.batch.size boundary (2048)
- **Wave 6**: CPU budget exhaustion threshold (multi-batch sustained load)
- **Waves 7–8**: KRaft controller timeout boundary (sustained CPU starvation > 5s)

The gap between waves 6 and 8 is intentionally large (5000 → 10000 → 25000) because once CPU saturates, the failure mode is binary: either KRaft survives or it doesn't. Fine-grained steps in this range would not yield additional insight.

---

## 5. Test Procedure

### 5.1 Pre-Test Checklist

Before starting:

1. All pods are `Running` and `Ready`
2. Both CDC connectors show `READY=True`
3. Silver tables contain the expected baseline data (4 users, 5 events)
4. No pending Strimzi reconciliations
5. System has been idle for at least 2 minutes

### 5.2 Execution Order

We run **PostgreSQL waves first** (users), then **MongoDB waves** (events). This avoids concurrent stress on both databases, which would conflate the results.

Each database gets the full wave sequence: 1 → 10 → 100 → 500 → 2048 → 5000 → 10000 → 25000.

If the system breaks at wave N, we:
1. Record the failure mode
2. Wait for recovery (or manually recover: delete crashed pods, reset Connect backoff)
3. Do NOT continue to wave N+1 — the breaking point has been found

### 5.3 Recovery Between Waves

After each wave:
1. Wait 30 seconds for the system to stabilize
2. Verify all pods are still Running
3. Verify connector status is READY=True
4. If any component crashed, wait for automatic recovery or manually intervene
5. Record recovery time as an additional data point

---

## 6. Limitations and Caveats

1. **Single-node bias**: A real production cluster would have dedicated nodes for Kafka, databases, and ClickHouse. Our breaking point is artificially low due to CPU contention on one Kind node.

2. **Polling latency floor**: Both Debezium and ClickHouse use 500ms poll intervals. The minimum theoretical e2e latency is ~1s even for a single row. This is a design choice, not a bottleneck.

3. **Measurement granularity**: We poll ClickHouse every 2 seconds. Actual e2e latency could be up to 2s lower than reported.

4. **Cold vs warm**: The first wave after a period of inactivity may be slower due to JVM warmup (Debezium/Connect) and ClickHouse query cache misses.

5. **WAL vs oplog differences**: PostgreSQL WAL and MongoDB oplog have different characteristics. PostgreSQL generates more data per row (full tuple logging). MongoDB oplog entries are more compact. Results may differ between the two databases.

---

## 7. Output Format

Results will be recorded in [phase5-stress-test-results.md](phase5-stress-test-results.md) with:

- A summary table per database (wave, N, e2e latency, throughput, system health)
- Health indicator snapshots at each wave
- The identified breaking point and failure mode
- An **Outcomes** section with conclusions and recommendations
