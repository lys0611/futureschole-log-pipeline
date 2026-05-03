# Lab01 Docker Compose

This Compose setup runs MySQL, the API server, traffic generator, Filebeat, and Logstash on one VM. Kafka is not created by Compose.

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

For plaintext Kafka, both values can be the same broker list.

## Run

```sh
docker compose up --build
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
