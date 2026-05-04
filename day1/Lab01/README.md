# Lab01 Docker Compose

This Compose setup runs MySQL, the API server, traffic generator, Filebeat, Logstash, and Kafka Connect on one VM. Kafka is not created by Compose.

It preserves two analytics paths:
- Nginx access logs: `traffic-generator -> api-server -> filebeat -> logstash -> external Kafka nginx-topic -> S3 sink -> Cloud Storage JSON`
- MySQL business tables: `mysql binlog -> Debezium MySQL source -> external Kafka mysql-server.shopdb.* -> S3 sink -> Cloud Storage JSON`

## External Kafka Assumptions

Create Kafka manually in your cloud provider before starting Compose.

Required:
- Kafka brokers are reachable from this VM.
- The broker list is provided through `.env`.
- `nginx-topic`, Kafka Connect internal topics, Debezium schema history topic, and `mysql-server.shopdb.*` topics exist, or your Kafka service allows automatic topic creation.
- No Kafka broker IPs or credentials are hardcoded in Compose.
- Kafka Connect uses SASL_SSL/PLAIN through the same external Kafka environment variables as Logstash.

Create `.env` from the example:

```sh
cp .env.example .env
```

Set:
- `KAFKA_BOOTSTRAP_SERVERS`
- `LOGSTASH_KAFKA_ENDPOINT`
- `KAFKA_SECURITY_PROTOCOL`
- `KAFKA_SASL_MECHANISM`
- `KAFKA_SASL_USERNAME`
- `KAFKA_SASL_PASSWORD`
- `MYSQL_DEBEZIUM_USER`
- `MYSQL_DEBEZIUM_PASSWORD`

## Object Storage

Kafka Connect registers two S3 sink connectors:
- `nginx-s3-sink-connector` archives `nginx-topic` events as raw JSON under `$S3_TOPICS_DIR/nginx-json-logs`.
- `mysql-cdc-s3-sink-connector` archives flattened Debezium CDC JSON from `mysql-server.shopdb.*` topics under `$S3_TOPICS_DIR/mysql-cdc`.

The MySQL source connector is `mysql-source-connector`. It reads the MySQL binlog with Debezium and uses `ExtractNewRecordState` so CDC messages are easier to query in BigQuery.

This setup does not add local Kafka, Schema Registry, Avro, or Parquet.

Required Object Storage variables:
- `BUCKET_NAME`
- `OBJECT_STORAGE_ENDPOINT`
- `OBJECT_STORAGE_REGION`
- `OBJECT_STORAGE_ACCESS_KEY`
- `OBJECT_STORAGE_SECRET_KEY`
- `S3_TOPICS_DIR`

If `mysql-compose-data` already exists, MySQL entrypoint init scripts are not replayed. The Debezium user script runs automatically on a fresh MySQL volume.

## Run

```sh
docker compose up --build -d
```

## Validate

API health:

```sh
curl http://localhost:8080/health
```

Filebeat and Logstash:

```sh
docker compose logs filebeat
docker compose logs logstash
```

Kafka topic and messages should be validated with your cloud Kafka tooling. Confirm that `nginx-topic` receives Nginx access log events after the traffic generator starts.

Kafka Connect and Object Storage:

```sh
curl http://localhost:8083/connectors
curl http://localhost:8083/connectors/nginx-s3-sink-connector/status
curl http://localhost:8083/connectors/mysql-source-connector/status
curl http://localhost:8083/connectors/mysql-cdc-s3-sink-connector/status
gcloud storage ls -r gs://$BUCKET_NAME/$S3_TOPICS_DIR/**
```
