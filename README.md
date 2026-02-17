# Barakah Data Engineering Challenge

## Project Overview
This project simulates a production-grade data engineering platform running locally on Kubernetes (Kind). It implements a **Change Data Capture (CDC)** pipeline that streams data from transactional databases into an analytical warehouse for real-time reporting.

**Architecture Flow**:
1.  **Sources**: PostgreSQL (Users) & MongoDB (Events)
2.  **Streaming**: Debezium captures changes and streams them to Kafka (KRaft mode).
3.  **Ingestion**: ClickHouse consumes Kafka topics into Silver tables.
4.  **Orchestration**: Airflow updates aggregates daily into Gold tables.

## Tech Stack
-   **Platform**: [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker)
-   **Streaming**: [Strimzi](https://strimzi.io/) (Kafka on K8s), [Debezium](https://debezium.io/) (CDC Connectors)
-   **Analytics**: [Altinity Operator](https://github.com/Altinity/clickhouse-operator) (ClickHouse)
-   **Orchestration**: [Apache Airflow](https://airflow.apache.org/)

## Prerequisites
Ensure the following tools are installed and available in your PATH:
-   [Docker Desktop](https://www.docker.com/products/docker-desktop/)
-   [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/)
-   [kubectl](https://kubernetes.io/docs/tasks/tools/)
-   [Helm](https://helm.sh/docs/intro/install/)

## Quick Start
1.  **Clone the repository**:
    ```bash
    git clone https://github.com/your-username/data-engineering-challenge.git
    cd data-engineering-challenge
    ```

2.  **Create the Kubernetes Cluster**:
    ```bash
    kind create cluster --config kind-config.yaml --name data-engineering-challenge
    ```

3.  **Deploy Infrastructure** (Kafka, Databases, Connectors):
    Apply manifests from the `infrastructure/` directory:
    ```bash
    kubectl apply -f infrastructure/
    ```

## Repository Structure

```
.
├── infrastructure/      # Kubernetes manifests (YAML)
│   ├── kafka-cluster.yaml      # Strimzi Kafka Cluster (KRaft)
│   ├── kafka-connect.yaml      # Kafka Connect Deployment
│   └── *-connector.yaml        # Debezium Connector configs
├── dags/                # Airflow DAGs (Python)
├── scripts/             # Database seeding and utility scripts
│   ├── seed_postgres.sql
│   └── seed_mongo.js
├── kind-config.yaml     # Kind cluster configuration
└── README.md            # Project documentation
```
