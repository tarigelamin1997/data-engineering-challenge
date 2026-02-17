#!/bin/bash
set -e

echo "Generating custom properties..."
cat <<EOF > /tmp/custom-connect.properties
bootstrap.servers=${BOOTSTRAP_SERVERS:-my-cluster-kafka-bootstrap:9092}
group.id=connect-cluster
key.converter=org.apache.kafka.connect.json.JsonConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
key.converter.schemas.enable=false
value.converter.schemas.enable=false
offset.storage.topic=connect-cluster-offsets
config.storage.topic=connect-cluster-configs
status.storage.topic=connect-cluster-status
offset.storage.replication.factor=1
config.storage.replication.factor=1
status.storage.replication.factor=1
rest.port=8083
rest.advertised.host.name=$(hostname)
rest.advertised.port=8083
plugin.path=/opt/kafka/plugins
EOF

echo "Starting Kafka Connect with custom properties..."
export KAFKA_LOG4J_OPTS="-Dlog4j.configuration=file:/opt/kafka/config/connect-log4j.properties"

# Ensure plugins dir exists
mkdir -p /opt/kafka/plugins

# Use exec to replace shell with Java process
exec /opt/kafka/bin/connect-distributed.sh /tmp/custom-connect.properties
