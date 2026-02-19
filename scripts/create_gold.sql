-- ==========================================
-- GOLD LAYER: gold_user_activity
-- ==========================================
-- This table is populated daily by the Airflow DAG.
-- It aggregates events per user per day by event type.
-- ReplacingMergeTree on (_updated_at) allows the DAG to re-run idempotently:
-- a re-run for the same date inserts new rows with a newer _updated_at,
-- and ClickHouse's FINAL keyword merges them on read.

CREATE TABLE IF NOT EXISTS gold_user_activity (
    date        Date,
    user_id     Int32,
    full_name   String,
    email       String,
    event_type  String,
    event_count UInt64,
    _updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_updated_at)
ORDER BY (date, user_id, event_type);
