# Phase 6: Grafana Dashboard

## Objective

Add a live observability dashboard to the CDC pipeline using Grafana with a native ClickHouse datasource plugin. This provides real-time visibility into data flowing through the system without any third-party drivers or external dependencies.

---

## Architecture

```
localhost:3000  ←─ kubectl port-forward ←─  grafana pod (monitoring ns)
                                                   │
                                      grafana-clickhouse-datasource plugin
                                                   │
                                       HTTP :8123 (database ns)
                                       chi-chi-clickhouse-my-cluster-0-0
                                       user=airflow / password=airflow123
```

Grafana runs as a ClusterIP service in the `monitoring` namespace. Access is via `kubectl port-forward` to `localhost:3000` — no NodePort needed.

---

## Components Deployed

| Component | Namespace | Details |
|-----------|-----------|---------|
| Grafana pod | `monitoring` | Helm chart `grafana/grafana`, 100m/256Mi request |
| ClickHouse datasource | provisioned | `grafana-clickhouse-datasource` plugin (installed at pod startup) |
| Dashboard ConfigMap | `monitoring` | `grafana-cdc-dashboard` — 5-panel dashboard as JSON |

---

## Dashboard Panels

The dashboard **CDC Pipeline Overview** (`/d/cdc-pipeline-v1/`) contains 5 panels:

| Panel | Type | Query | What It Shows |
|-------|------|-------|---------------|
| CDC Throughput — Events/min | Time series | `SELECT toStartOfMinute(_ingested_at) AS time, count() AS events_per_minute FROM events_silver WHERE $__timeFilter(_ingested_at) GROUP BY time ORDER BY time` | Real-time event ingestion rate |
| Active Users | Stat | `SELECT count() FROM users_silver FINAL WHERE is_deleted = 0` | Deduplicated count of non-deleted users |
| Total Events | Stat | `SELECT count() FROM events_silver` | Total event count in the silver table |
| CDC Throughput — Users/min | Time series | `SELECT toStartOfMinute(_ingested_at) AS time, count() FROM users_silver WHERE $__timeFilter(_ingested_at) GROUP BY time ORDER BY time` | User ingestion rate |
| Gold Layer Summary | Table | `SELECT date, user_id, full_name, email, total_events, last_event_at FROM gold_user_activity FINAL` | Latest aggregated user activity |

Auto-refresh: **30 seconds**. Default time range: **last 6 hours**.

---

## Key Files

| File | Purpose |
|------|---------|
| `infrastructure/grafana-values.yaml` | Helm values: credentials, datasource, plugin, dashboard provider, resources |
| `infrastructure/grafana-dashboard-configmap.yaml` | Dashboard JSON as a Kubernetes ConfigMap |
| `docs/phase6-grafana-dashboard.md` | This document |

---

## Deployment Steps

```bash
# 1. Add Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

# 2. Create namespace
kubectl create namespace monitoring

# 3. Apply dashboard ConfigMap
kubectl apply -f infrastructure/grafana-dashboard-configmap.yaml

# 4. Install Grafana
helm install grafana grafana/grafana \
  --namespace monitoring \
  --values infrastructure/grafana-values.yaml \
  --timeout 5m

# 5. Wait for pod (plugin download takes 30-60s)
kubectl wait pod -n monitoring -l app.kubernetes.io/name=grafana \
  --for=condition=Ready --timeout=120s

# 6. Port-forward
kubectl port-forward svc/grafana 3000:3000 -n monitoring

# 7. Open browser
# http://localhost:3000  →  admin / admin
# Dashboard: http://localhost:3000/d/cdc-pipeline-v1/cdc-pipeline-overview
```

---

## Verification

1. **Pod is Running**:
   ```bash
   kubectl get pods -n monitoring
   # grafana-...   1/1   Running
   ```

2. **Datasource is connected**:
   ```bash
   kubectl exec -n monitoring deployment/grafana -- \
     curl -s http://admin:admin@localhost:3000/api/datasources/uid/clickhouse/health
   # {"message":"Data source is working","status":"OK"}
   ```

3. **Dashboard has data**: Open the dashboard URL — all 5 panels should show data. The time-series panels need events within the selected time range (default: last 6 hours).

4. **Live test**: Insert a row into MongoDB or PostgreSQL and watch the throughput panel update within 30 seconds:
   ```bash
   kubectl exec -n database <postgres-pod> -- \
     psql -U postgres -c "INSERT INTO users (full_name, email) VALUES ('Live Test', 'live@test.com');"
   ```

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Pod stuck in `Init` state | Plugin downloading from grafana.com | Wait 60s. Check: `kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c init-chown-data` |
| "Data source is not working" | ClickHouse pod not ready or wrong credentials | Verify: `kubectl get pods -n database`, check `airflow` user exists in ClickHouse |
| Dashboard shows "No data" on time series | No events in selected time range | Change time range to "Last 7 days" or insert new data |
| Gold panel empty | Airflow DAG hasn't run | Run: `kubectl exec -n airflow deployment/airflow-dag-processor -c dag-processor -- airflow dags test gold_user_activity 2026-02-22` |
| Port 3000 already in use | Another process on 3000 | Use a different local port: `kubectl port-forward svc/grafana 3001:3000 -n monitoring` |

---

## Why Port-Forward Instead of NodePort

The Kind cluster's `kind-config.yaml` maps NodePort 30001 to host port 5432. Using `localhost:5432` for Grafana would be confusing (looks like PostgreSQL). Port-forward to `localhost:3000` is the conventional Grafana access pattern and requires no cluster reconfiguration.

---

## Quick Reference

```bash
# Start Grafana access
kubectl port-forward svc/grafana 3000:3000 -n monitoring

# Check Grafana pod
kubectl get pods -n monitoring

# Test datasource
kubectl exec -n monitoring deployment/grafana -- \
  curl -s http://admin:admin@localhost:3000/api/datasources/uid/clickhouse/health

# Dashboard URL
http://localhost:3000/d/cdc-pipeline-v1/cdc-pipeline-overview

# Credentials
admin / admin
```
