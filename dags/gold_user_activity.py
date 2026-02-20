"""
gold_user_activity DAG — Phase 4 Gold Layer

Runs daily. For each user, summarises their total number of events and the
timestamp of their last event for the previous day.

Schedule: @daily (runs at midnight UTC, processes the previous calendar day)
Idempotent: re-running for the same date inserts new rows with a newer
            _updated_at; querying with FINAL returns only the latest version.

ClickHouse connection uses the HTTP interface (port 8123) via requests —
no extra Python packages needed beyond what Airflow already ships.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import requests
from airflow import DAG
from airflow.providers.standard.operators.python import PythonOperator

CLICKHOUSE_URL = (
    "http://chi-chi-clickhouse-my-cluster-0-0.database.svc.cluster.local:8123/"
)
CLICKHOUSE_AUTH = {"user": "airflow", "password": "airflow123"}


def _run_ch_query(query: str) -> str:
    """Execute a ClickHouse query via HTTP and return the response body."""
    resp = requests.post(CLICKHOUSE_URL, params=CLICKHOUSE_AUTH, data=query.encode())
    resp.raise_for_status()
    return resp.text.strip()


def compute_gold_user_activity(ds: str, **_) -> None:
    """
    For the given execution date `ds` (YYYY-MM-DD), join users_silver and
    events_silver, and for each user compute the total number of events and
    the timestamp of their last event for that day.

    Using FINAL on users_silver ensures we get the latest (deduplicated) state
    of each user.
    """
    query = f"""
        INSERT INTO gold_user_activity
            (date, user_id, full_name, email, total_events, last_event_at)
        SELECT
            toDate(e.timestamp)         AS date,
            u.user_id,
            anyLast(u.full_name)        AS full_name,
            anyLast(u.email)            AS email,
            count()                     AS total_events,
            max(e.timestamp)            AS last_event_at
        FROM events_silver AS e
        INNER JOIN (
            SELECT user_id, full_name, email
            FROM   users_silver FINAL
            WHERE  is_deleted = 0
        ) AS u ON e.user_id = u.user_id
        WHERE toDate(e.timestamp) = toDate('{ds}')
        GROUP BY date, u.user_id
    """
    _run_ch_query(query)
    print(f"[gold_user_activity] Inserted gold rows for date={ds}")


with DAG(
    dag_id="gold_user_activity",
    description="Daily aggregation of user events into the gold layer",
    schedule="@daily",
    start_date=datetime(2026, 2, 18),
    catchup=False,
    tags=["gold", "clickhouse", "phase4"],
    default_args={
        "retries": 2,
        "retry_delay": timedelta(minutes=5),
    },
) as dag:
    compute = PythonOperator(
        task_id="compute_gold_user_activity",
        python_callable=compute_gold_user_activity,
    )