"""
gold_user_activity DAG — Phase 4 Gold Layer (dbt)

Runs daily. Uses dbt to transform silver layer tables into the gold_user_activity
summary: for each user, total events and last event timestamp per day.

Schedule: @daily (runs at midnight UTC, processes the previous calendar day)
Idempotent: dbt incremental + ReplacingMergeTree(_updated_at) ensures re-runs
            produce correct results when queried with FINAL.

Architecture note:
  - Kind cluster: dbt runs locally via BashOperator pattern (dbt not in Airflow image).
    The DAG documents the production orchestration pattern.
  - Production: replace BashOperator with KubernetesPodOperator running a dbt Docker image.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.standard.operators.bash import BashOperator

DBT_PROJECT_DIR = "/opt/airflow/dbt"

with DAG(
    dag_id="gold_user_activity",
    description="Daily dbt transformation: silver → gold user activity summary",
    schedule="@daily",
    start_date=datetime(2026, 2, 18),
    catchup=False,
    tags=["gold", "clickhouse", "dbt", "phase4"],
    default_args={
        "retries": 2,
        "retry_delay": timedelta(minutes=5),
    },
) as dag:
    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --select gold_user_activity",
    )

    dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt test --select gold_user_activity",
    )

    dbt_run >> dbt_test
