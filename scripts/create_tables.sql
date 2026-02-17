-- CLEANUP
DROP TABLE IF EXISTS users_queue;
DROP TABLE IF EXISTS users_silver;
DROP TABLE IF EXISTS mv_users;
DROP TABLE IF EXISTS events_queue;
DROP TABLE IF EXISTS events_silver;
DROP TABLE IF EXISTS mv_events;

-- ==========================================
-- 1. USERS PIPELINE (Postgres)
-- ==========================================

-- Bronze: Kafka Engine (JSONEachRow to capture Debezium envelope)
CREATE TABLE users_queue (
    before String,
    after String,
    source String,
    op String,
    ts_ms UInt64
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
    kafka_topic_list = 'postgres.public.users',
    kafka_group_name = 'ch_users_consumer',
    kafka_format = 'JSONEachRow';

-- Silver: ReplacingMergeTree (Deduplication + Versioning)
CREATE TABLE users_silver (
    user_id Int32,
    full_name String,
    email String,
    updated_at DateTime,
    _version UInt64,
    is_deleted UInt8,
    _ingested_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_version)
ORDER BY user_id;

-- Materialized View: Transform and Load
CREATE MATERIALIZED VIEW mv_users TO users_silver AS
SELECT
    -- Handle Deletes: 'after' is null, so get ID from 'before'
    coalesce(
        JSONExtract(after, 'user_id', 'Int32'),
        JSONExtract(before, 'user_id', 'Int32')
    ) as user_id,
    
    JSONExtract(after, 'full_name', 'String') as full_name,
    JSONExtract(after, 'email', 'String') as email,
    
    -- Parse timestamp (handled safely)
    toDateTime(
        coalesce(
            JSONExtract(after, 'updated_at', 'Int64') / 1000000, -- Microseconds to Seconds? Postgres 'timestamp' usually micros in Debezium? Or milliseconds?
            -- Fallback or default
            now() 
        )
    ) as updated_at,
    
    ts_ms as _version,
    if(op == 'd', 1, 0) as is_deleted
FROM users_queue
WHERE op != 'r'; -- Skip 'read' snapshot events if preferred, or keep them. Usually 'r', 'c', 'u', 'd'. We keep 'r' (snapshot).

-- ==========================================
-- 2. EVENTS PIPELINE (MongoDB)
-- ==========================================

-- Bronze: Kafka Engine
CREATE TABLE events_queue (
    after String,
    source String,
    op String,
    ts_ms UInt64
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
    kafka_topic_list = 'mongo.commerce.events',
    kafka_group_name = 'ch_events_consumer',
    kafka_format = 'JSONEachRow';

-- Silver: MergeTree (Append Only)
CREATE TABLE events_silver (
    user_id Int32,
    event_type String,
    timestamp DateTime,
    metadata String,
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY (user_id, timestamp);

-- Materialized View
CREATE MATERIALIZED VIEW mv_events TO events_silver AS
SELECT
    JSONExtract(after, 'user_id', 'Int32') as user_id,
    JSONExtract(after, 'event_type', 'String') as event_type,
    
    -- Handle Mongo Date (often comes as milliseconds in Debezium JSON)
    toDateTime(
        JSONExtract(after, 'timestamp', 'Int64') / 1000
    ) as timestamp,

    -- Extract nested JSON object as string
    JSONExtract(after, 'metadata', 'String') as metadata
FROM events_queue;
