# Lab01 Docker Compose

This Compose setup runs MySQL, the API server, traffic generator, Filebeat, Logstash, and Kafka Connect on one VM. Kafka is not created by Compose.

## External Kafka Assumptions

Create Kafka manually in your cloud provider before starting Compose.

Required:
- Kafka brokers are reachable from this VM.
- The broker list is provided through `.env`.
- The `nginx-topic` topic exists, or your Kafka service allows automatic topic creation.
- No Kafka broker IPs or credentials are hardcoded in Compose.

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

## Raw Nginx Log Archive

Kafka Connect registers one S3 sink connector, `nginx-s3-sink-connector`, that archives `nginx-topic` events as raw JSON objects under `raw-nginx-logs/`.

This is only a raw log archive. It is not the required field-separated MySQL storage, and it does not add Debezium, MySQL CDC, Schema Registry, Avro, or Parquet.

Required Object Storage variables:
- `BUCKET_NAME`
- `OBJECT_STORAGE_ENDPOINT`
- `OBJECT_STORAGE_REGION`
- `OBJECT_STORAGE_ACCESS_KEY`
- `OBJECT_STORAGE_SECRET_KEY`

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
gcloud storage ls -r gs://$BUCKET_NAME/**
```
