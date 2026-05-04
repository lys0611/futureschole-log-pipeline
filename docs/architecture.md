# 아키텍처

이 프로젝트는 application과 수집 agent를 단일 VM의 Docker Compose로 실행하고, Kafka, object storage, analytics, visualization은 GCP 관리형 서비스를 사용합니다.

```text
VM-local Docker Compose

traffic-generator
  -> api-server Nginx:80
      -> Gunicorn/Flask:8080
          -> mysql:3306

api-server Nginx access log
  -> filebeat
      -> logstash:5044
          -> external GCP Managed Kafka nginx-topic

mysql binlog
  -> kafka-connect mysql-source-connector
      -> external GCP Managed Kafka mysql-server.shopdb.* topics

external GCP Managed Kafka topics
  -> kafka-connect nginx-s3-sink-connector
      -> Cloud Storage raw/nginx-json-logs
  -> kafka-connect mysql-cdc-s3-sink-connector
      -> Cloud Storage raw/mysql-cdc

Cloud Storage JSON
  -> BigQuery external tables
      -> BigQuery views
          -> Looker Studio dashboard
```

## VM 내부 컴포넌트

| Service | 역할 |
| --- | --- |
| `traffic-generator` | FSM 기반 traffic simulator를 continuous mode로 실행합니다. |
| `api-server` | Container 내부에서 Nginx `80`번 port와 Gunicorn/Flask `8080`번 port를 실행합니다. |
| `mysql` | 비즈니스 domain data를 저장하고 Debezium이 읽을 binlog를 생성합니다. |
| `filebeat` | Shared Docker volume의 Nginx access log file을 tailing합니다. |
| `logstash` | Nginx JSON log를 parsing하고 `nginx-topic`으로 전송합니다. |
| `kafka-connect` | `8083`번 port에서 하나의 Kafka Connect worker를 실행합니다. |
| `connector-init` | Kafka Connect REST API가 준비될 때까지 기다린 뒤 세 connector를 idempotent하게 등록합니다. |

## 외부 GCP 관리형 서비스

| Service | 역할 |
| --- | --- |
| GCP Managed Kafka | `nginx-topic`, Kafka Connect internal topic, Debezium schema history topic, MySQL CDC topic을 저장합니다. |
| Cloud Storage | Kafka Connect S3 Sink Connector의 raw JSON archive 저장소입니다. |
| BigQuery | Cloud Storage JSON 위에 external table과 view를 제공합니다. |
| Looker Studio | BigQuery view를 기반으로 최종 dashboard를 제공합니다. |

## Connector 흐름

| Connector | Source | Sink |
| --- | --- | --- |
| `nginx-s3-sink-connector` | `nginx-topic` | `gs://$BUCKET_NAME/$S3_TOPICS_DIR/nginx-json-logs/nginx-topic/partition=0/*` |
| `mysql-source-connector` | MySQL binlog | `mysql-server.shopdb.*` Kafka topics |
| `mysql-cdc-s3-sink-connector` | `mysql-server.shopdb.*` Kafka topics | `gs://$BUCKET_NAME/$S3_TOPICS_DIR/mysql-cdc/...` |

현재 runtime에는 local Kafka, Schema Registry, Avro, Parquet service가 포함되지 않습니다. Kafka는 외부 GCP Managed Kafka를 사용하고, raw archive는 JSON 형식으로 Cloud Storage에 저장합니다.
