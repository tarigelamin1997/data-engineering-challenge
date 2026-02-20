# Phase 2: Kafka Cluster (KRaft Mode)

## Objective

Deploy a Kafka cluster in KRaft mode (no ZooKeeper) using the Strimzi operator, and build a custom Kafka Connect image that bundles the Debezium CDC connectors. This phase establishes the streaming backbone that all downstream components depend on.

---

## Components Deployed

| Component | Resource | Namespace | Details |
|---|---|---|---|
| Kafka Node Pool | `my-pool` (KafkaNodePool) | `kafka` | 1 node, combined controller + broker role, ephemeral storage |
| Kafka Cluster | `my-cluster` (Kafka CR) | `kafka` | KRaft mode, Kafka 4.0.0, plain + TLS listeners |
| Entity Operator | Deployment (auto-created) | `kafka` | Topic Operator + User Operator, managed by Strimzi |
| Kafka Connect | `my-connect-cluster` (KafkaConnect CR) | `kafka` | 1 replica, custom image `my-final-connect:1.1` |

---

## Architecture

```
Strimzi Operator
  └── manages:
        ├── Kafka Cluster (KRaft, 1 broker)
        │     ├── Listener: plain (port 9092, no TLS)
        │     └── Listener: tls   (port 9093)
        ├── Entity Operator (Topic + User)
        └── Kafka Connect (1 replica)
              ├── Debezium PostgreSQL Connector plugin
              └── Debezium MongoDB Connector plugin
```

### Internal Addresses

| Service | Address | Port |
|---|---|---|
| Kafka Bootstrap | `my-cluster-kafka-bootstrap.kafka.svc.cluster.local` | 9092 |
| Kafka Connect REST API | `my-connect-cluster-connect-api.kafka.svc.cluster.local` | 8083 |

---

## Key Files

| File | Purpose |
|---|---|
| [infrastructure/kraft-cluster.yaml](../infrastructure/kraft-cluster.yaml) | KafkaNodePool + Kafka CR (KRaft, version 4.0.0) |
| [infrastructure/kafka-connect.yaml](../infrastructure/kafka-connect.yaml) | KafkaConnect CR — custom image, secret mounts, config providers |
| [infrastructure/Dockerfile.final](../infrastructure/Dockerfile.final) | Hybrid Connect image: Strimzi base + Debezium 2.7.0 plugins |

---

## The Custom Connect Image

### Why a Custom Image Is Needed

The Strimzi operator manages Kafka Connect pods and expects its own startup script (`/opt/kafka/kafka_connect_run.sh`) to be present. Off-the-shelf Debezium images don't include this script. At the same time, the stock Strimzi image doesn't include any connector plugins.

**Solution**: A hybrid image that uses the Strimzi Kafka base image and adds Debezium connector JARs on top.

### Image: `my-final-connect:1.1`

**Base**: `quay.io/strimzi/kafka:0.50.0-kafka-4.0.0`

**Plugins added**:
- `debezium-connector-postgres` 2.7.0.Final → `/opt/kafka/plugins/debezium-postgres/`
- `debezium-connector-mongodb` 2.7.0.Final → `/opt/kafka/plugins/debezium-mongo/`

**Critical fix applied**: Debezium 2.7.0 bundles `slf4j-reload4j.jar` (a log4j v1 SLF4J binding) that conflicts with Strimzi's log4j2 setup. The Dockerfile removes these JARs to prevent a JVM crash at startup.

See [infrastructure/Dockerfile.final](../infrastructure/Dockerfile.final) for the full build definition.

### Building and Loading

```bash
# Build the image
docker build -f infrastructure/Dockerfile.final -t my-final-connect:1.1 .

# Load into Kind (always use a new tag to bypass caching)
kind load docker-image my-final-connect:1.1 --name data-engineering-challenge
```

---

## Kafka Cluster Configuration

From [infrastructure/kraft-cluster.yaml](../infrastructure/kraft-cluster.yaml):

| Setting | Value | Reason |
|---|---|---|
| `version` | `4.0.0` | Latest Kafka supported by Strimzi 0.50.0 |
| KRaft mode | Enabled via annotations | No ZooKeeper dependency — simpler, fewer pods |
| Node pool roles | `controller` + `broker` | Single combined node (sufficient for dev) |
| Storage | `ephemeral` | No PVCs needed for local development |
| `offsets.topic.replication.factor` | `1` | Single broker — cannot replicate |
| `default.replication.factor` | `1` | Same reason |
| `min.insync.replicas` | `1` | Same reason |

---

## Kafka Connect Configuration

From [infrastructure/kafka-connect.yaml](../infrastructure/kafka-connect.yaml):

| Setting | Value |
|---|---|
| Image | `my-final-connect:1.1` |
| Bootstrap servers | `my-cluster-kafka-bootstrap:9092` |
| Group ID | `connect-cluster` |
| Key/Value converter | `JsonConverter` (schemas disabled) |
| Replication factors | `1` (all internal topics) |

### Internal Topics

Connect uses three internal Kafka topics for its state:

| Topic | Purpose |
|---|---|
| `connect-cluster-offsets` | Tracks connector source offsets (Debezium WAL positions) |
| `connect-cluster-configs` | Stores connector configurations |
| `connect-cluster-status` | Connector and task status |

All three **must** have `cleanup.policy=compact`. After a cluster restart, they may be recreated with `cleanup.policy=delete`, which causes Connect to fail with HTTP 500 errors. Fix with:

```bash
for topic in connect-cluster-offsets connect-cluster-configs connect-cluster-status; do
  kubectl exec -n kafka my-cluster-my-pool-0 -- \
    /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
    --entity-type topics --entity-name $topic \
    --alter --add-config cleanup.policy=compact
done
```

### Secret Injection via DirectoryConfigProvider

Database passwords are mounted from Kubernetes Secrets into the Connect pod as files:

| Mount Path | Secret | Key |
|---|---|---|
| `/mnt/postgres-auth/password` | `postgres-credentials` | `password` |
| `/mnt/mongo-auth/password` | `mongo-credentials` | `password` |

Connectors reference passwords using Strimzi's `DirectoryConfigProvider`:

```
${strimzidir:/mnt/postgres-auth:password}
```

The `allowed.paths` setting in `kafka-connect.yaml` must include `/mnt`:

```yaml
config.providers.strimzidir.param.allowed.paths: /opt/kafka,/mnt
```

### Readiness and Liveness Probes

Both probes have a **300-second (5-minute) initial delay** because Connect takes several minutes to start on a CPU-constrained Kind cluster. The pod shows `0/1 Running` during this period — this is normal.

---

## Deployment Steps

### 1. Deploy the Kafka Cluster

```bash
kubectl apply -f infrastructure/kraft-cluster.yaml
```

Wait for the cluster to be ready:

```bash
kubectl wait kafka/my-cluster -n kafka --for=condition=Ready --timeout=300s
```

### 2. Build and Load the Connect Image

```bash
docker build -f infrastructure/Dockerfile.final -t my-final-connect:1.1 .
kind load docker-image my-final-connect:1.1 --name data-engineering-challenge
```

### 3. Deploy Kafka Connect

```bash
kubectl apply -f infrastructure/kafka-connect.yaml
```

Wait for Connect to become ready (up to 10 minutes on slow machines):

```bash
kubectl wait kafkaconnect/my-connect-cluster -n kafka --for=condition=Ready --timeout=600s
```

---

## Verification

```bash
# Kafka broker pod is running
kubectl get pods -n kafka -l strimzi.io/name=my-cluster-my-pool

# Kafka cluster is Ready
kubectl get kafka -n kafka

# Connect pod is 1/1 Running
kubectl get pods -n kafka -l strimzi.io/cluster=my-connect-cluster

# Connect REST API responds
kubectl exec -n kafka my-connect-cluster-connect-0 -- curl -s localhost:8083/
# Expected: {"version":"4.0.0", ...}

# Connector plugins are loaded
kubectl exec -n kafka my-connect-cluster-connect-0 -- curl -s localhost:8083/connector-plugins | grep -o '"class":"[^"]*"'
# Expected: io.debezium.connector.postgresql.PostgresConnector
#           io.debezium.connector.mongodb.MongoDbConnector

# Internal topics created
kubectl exec -n kafka my-cluster-my-pool-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
# Expected: __consumer_offsets, connect-cluster-configs, connect-cluster-offsets, connect-cluster-status
```

---

## Issues Encountered and Resolved

### 1. slf4j-reload4j Classpath Conflict (CrashLoopBackOff)

Debezium 2.7.0 bundles `slf4j-reload4j.jar` which conflicts with Strimzi's log4j2 logging setup. The JVM crashes at `AbstractConnectCli.<clinit>` before Connect even starts.

**Fix**: Remove the conflicting JARs in the Dockerfile:
```dockerfile
RUN find /opt/kafka/plugins/ -name "slf4j-reload4j-*.jar" -delete \
    && find /opt/kafka/plugins/ -name "reload4j-*.jar" -delete
```

### 2. Kind Image Caching

Kind caches Docker images by tag. Running `kind load docker-image my-final-connect:1.0` twice does NOT update the image even if it was rebuilt.

**Fix**: Always bump the tag when rebuilding (`:1.0` → `:1.1`).

### 3. KafkaConnect Version Must Match Kafka

Setting `version: 3.7.0` in `kafka-connect.yaml` while the Kafka cluster runs `4.0.0` caused Connect to generate an empty `bootstrap.servers` config.

**Fix**: Set `version: 4.0.0` in the KafkaConnect CR to match.

### 4. Connect Internal Topics Cleanup Policy

After a cluster restart, the three internal topics may be recreated with `cleanup.policy=delete` (instead of `compact`). Connect then fails with HTTP 500 errors because it cannot read its own state.

**Fix**: Manually set `cleanup.policy=compact` on all three topics (see command above).

### 5. Connect Bootstrap Failure After Broker Restart

When the broker restarts, Connect may attempt to start before the broker is ready, exit with "No resolvable bootstrap urls", and enter exponential CrashLoopBackOff.

**Fix**: Delete the Connect pod once the broker is 1/1 Ready to reset the backoff timer:
```bash
kubectl delete pod -n kafka my-connect-cluster-connect-0
```
