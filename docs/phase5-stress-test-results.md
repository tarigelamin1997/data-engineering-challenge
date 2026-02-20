# Phase 5: Stress Test — Results

> **Methodology**: See [phase5-stress-test-methodology.md](phase5-stress-test-methodology.md) for test design, rationale, and measurement definitions.

## Test Environment

| Property | Value |
|----------|-------|
| Kind cluster | `data-engineering-challenge` (single node) |
| Docker Desktop resources | _To be filled before test_ |
| Kafka | Strimzi 0.50.0, KRaft, version 4.0.0 |
| Debezium | 2.7.0 (PostgreSQL + MongoDB connectors) |
| ClickHouse | 24.8 (Altinity operator) |
| Date | _To be filled_ |

---

## Pre-Test Baseline

| Check | Status |
|-------|--------|
| All pods Running | _To be filled_ |
| CDC connectors READY | _To be filled_ |
| users_silver count | _To be filled_ |
| events_silver count | _To be filled_ |

---

## Results: PostgreSQL → users_silver

| Wave | Rows (N) | e2e Latency (s) | Throughput (rows/s) | Broker Status | Connect Status | Notes |
|------|----------|-----------------|---------------------|---------------|----------------|-------|
| 1 | 1 | | | | | |
| 2 | 10 | | | | | |
| 3 | 100 | | | | | |
| 4 | 500 | | | | | |
| 5 | 2048 | | | | | |
| 6 | 5000 | | | | | |
| 7 | 10000 | | | | | |
| 8 | 25000 | | | | | |

**Breaking point (PostgreSQL)**: _To be determined_

---

## Results: MongoDB → events_silver

| Wave | Rows (N) | e2e Latency (s) | Throughput (rows/s) | Broker Status | Connect Status | Notes |
|------|----------|-----------------|---------------------|---------------|----------------|-------|
| 1 | 1 | | | | | |
| 2 | 10 | | | | | |
| 3 | 100 | | | | | |
| 4 | 500 | | | | | |
| 5 | 2048 | | | | | |
| 6 | 5000 | | | | | |
| 7 | 10000 | | | | | |
| 8 | 25000 | | | | | |

**Breaking point (MongoDB)**: _To be determined_

---

## System Health Snapshots

### Wave 5 (2048 rows)
```
# kubectl top nodes
# kubectl logs (broker) — last 10 lines
# kubectl get kafkaconnector -n kafka
```
_To be filled_

### Wave 6 (5000 rows)
_To be filled_

### Wave 7 (10000 rows)
_To be filled_

---

## Outcomes

### 1. Identified Breaking Point

_Summary of at which wave and row count each database pipeline broke, and the failure mode observed._

### 2. Bottleneck Analysis

_Which component failed first and why. Was the prediction from the methodology (CPU starvation → KRaft timeout) correct?_

### 3. Latency Characteristics

_How did e2e latency scale with row count? Was it linear, sub-linear, or did it jump at specific thresholds?_

### 4. Recommendations

_Based on results, what would improve throughput the most?_

- **If CPU-bound**: Increase Docker Desktop CPU allocation, or move to a multi-node Kind cluster
- **If Debezium-bound**: Tune `max.batch.size`, `poll.interval.ms`
- **If ClickHouse-bound**: Tune `kafka_poll_timeout_ms`, `kafka_max_block_size`
- **If Kafka-bound**: Increase broker resources, add partitions

### 5. Production Extrapolation

_Given that our Kind cluster has N vCPUs and broke at M rows/s, what throughput could we expect on a production cluster with dedicated nodes?_
