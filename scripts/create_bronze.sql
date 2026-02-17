-- Bronze Layer: Kafka Engine Tables

CREATE TABLE IF NOT EXISTS bronze_users (
    id Int32,
    name String,
    email String,
    created_at String
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
    kafka_topic_list = 'postgres.public.users',
    kafka_group_name = 'clickhouse_users_consumer',
    kafka_format = 'Debezium';

CREATE TABLE IF NOT EXISTS bronze_events (
    _id String,
    event_type String,
    amount Decimal(10,2),
    user_id Int32,
    timestamp String
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
    kafka_topic_list = 'mongo.commerce.events',
    kafka_group_name = 'clickhouse_events_consumer',
    kafka_format = 'Debezium';
