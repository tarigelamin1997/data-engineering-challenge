-- CLEANUP
DROP TABLE IF EXISTS mv_users;
DROP TABLE IF EXISTS mv_events;
DROP TABLE IF EXISTS users_queue;
DROP TABLE IF EXISTS events_queue;
DROP TABLE IF EXISTS users_silver;
DROP TABLE IF EXISTS events_silver;

-- ==========================================
-- 1. USERS PIPELINE (Postgres → Kafka → ClickHouse)
-- ==========================================

-- Bronze: Kafka Engine reads Debezium envelope as JSONEachRow.
-- ClickHouse stores nested JSON objects as strings (input_format_json_read_objects_as_strings=1 default).
CREATE TABLE users_queue (
    before String,
    after  String,
    source String,
    op     String,
    ts_ms  UInt64
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list         = 'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
    kafka_topic_list          = 'postgres.public.users',
    kafka_group_name          = 'ch_users_consumer',
    kafka_format              = 'JSONEachRow';

-- Silver: ReplacingMergeTree deduplicates by user_id using _version (ts_ms).
-- Always query with FINAL to get the latest version per user_id.
CREATE TABLE users_silver (
    user_id      Int32,
    full_name    String,
    email        String,
    updated_at   DateTime,
    _version     UInt64,
    is_deleted   UInt8,
    _ingested_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_version)
ORDER BY user_id;

-- Materialized View: transforms Debezium envelope into the silver schema.
-- All ops are captured: 'r' (snapshot), 'c' (insert), 'u' (update), 'd' (delete).
-- For deletes, 'after' is null so user_id is read from 'before'.
-- PostgreSQL TIMESTAMP is encoded by Debezium as microseconds since epoch.
CREATE MATERIALIZED VIEW mv_users TO users_silver AS
SELECT
    coalesce(
        JSONExtract(after,  'user_id', 'Int32'),
        JSONExtract(before, 'user_id', 'Int32')
    )                                                              AS user_id,
    JSONExtract(after, 'full_name', 'String')                     AS full_name,
    JSONExtract(after, 'email',     'String')                     AS email,
    toDateTime(
        toInt64OrZero(JSONExtractRaw(after, 'updated_at')) / 1000000
    )                                                              AS updated_at,
    ts_ms                                                          AS _version,
    if(op = 'd', 1, 0)                                            AS is_deleted
FROM users_queue;

-- ==========================================
-- 2. EVENTS PIPELINE (MongoDB → Kafka → ClickHouse)
-- ==========================================

-- Bronze: Kafka Engine.
-- The MongoDB connector serializes the full document into the 'after' column as a
-- JSON string. Nested Mongo Date fields use Extended JSON: {"$date": <epoch_ms>}.
CREATE TABLE events_queue (
    after  String,
    source String,
    op     String,
    ts_ms  UInt64
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list         = 'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
    kafka_topic_list          = 'mongo.commerce.events',
    kafka_group_name          = 'ch_events_consumer',
    kafka_format              = 'JSONEachRow';

-- Silver: MergeTree (append-only — MongoDB events are immutable facts).
CREATE TABLE events_silver (
    user_id      Int32,
    event_type   String,
    timestamp    DateTime,
    metadata     String,
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY (user_id, timestamp);

-- Materialized View: parse the Mongo Extended JSON document stored in 'after'.
-- The 'ts' field in MongoDB documents is a BSON Date, serialized as {"$date": <epoch_ms>}.
-- metadata is a nested object; ClickHouse captures it as a raw JSON string.
CREATE MATERIALIZED VIEW mv_events TO events_silver AS
SELECT
    JSONExtract(after, 'user_id',    'Int32')  AS user_id,
    JSONExtract(after, 'event_type', 'String') AS event_type,
    toDateTime(
        JSONExtract(JSONExtractRaw(after, 'ts'), '$date', 'Int64') / 1000
    )                                          AS timestamp,
    JSONExtractRaw(after, 'metadata')          AS metadata
FROM events_queue;
