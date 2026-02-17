-- Silver Layer: Materialized Views and Deduplication

CREATE TABLE IF NOT EXISTS silver_users (
    id Int32,
    name String,
    email String,
    created_at DateTime,
    _ingested_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree()
ORDER BY id;

CREATE MATERIALIZED VIEW mv_bronze_to_silver_users TO silver_users AS
SELECT
    id,
    name,
    email,
    toDateTime(created_at) as created_at
FROM bronze_users;

CREATE TABLE IF NOT EXISTS silver_events (
    event_id String,
    event_type String,
    amount Decimal(10,2),
    user_id Int32,
    timestamp DateTime,
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY timestamp;

CREATE MATERIALIZED VIEW mv_bronze_to_silver_events TO silver_events AS
SELECT
    _id as event_id,
    event_type,
    amount,
    user_id,
    toDateTime(timestamp) as timestamp
FROM bronze_events;
