# 검증 절차

이 문서는 `.env`에 실제 GCP/Kafka/Cloud Storage 값을 입력하고 Docker Compose를 시작한 뒤 repository root에서 실행하는 검증 명령을 정리합니다. 원래 검증 환경에서는 runtime pipeline이 테스트되었으며, 다른 환경에서의 최종 live 검증은 평가자별 `.env`와 GCP resource가 준비되어야 합니다.

## Compose

`.env.example`은 placeholder 값으로 Compose 구조만 확인할 때 사용합니다.

```sh
docker compose --env-file .env.example config --services
```

실제 `.env`를 입력한 뒤에는 다음 명령으로 service 구성을 확인합니다.

```sh
docker compose config --services
docker compose ps -a
```

예상 service는 다음과 같습니다. 출력 순서는 다를 수 있습니다.

```text
mysql
api-server
traffic-generator
logstash
filebeat
kafka-connect
connector-init
```

## API

```sh
curl -s http://localhost:8080/health
```

예상 응답:

```json
{"status":"ok"}
```

## MySQL

```sh
docker compose exec -T mysql mysql -uadmin -padmin1234 shopdb -e "
SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'sessions', COUNT(*) FROM sessions
UNION ALL SELECT 'cart_logs', COUNT(*) FROM cart_logs
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'reviews', COUNT(*) FROM reviews
UNION ALL SELECT 'search_logs', COUNT(*) FROM search_logs;"
```

정확한 row count는 traffic generator 실행 시간에 따라 달라집니다.

## Filebeat와 Logstash

```sh
docker compose logs --tail=100 filebeat
docker compose logs --tail=100 logstash
```

Filebeat가 `logstash:5044`로 연결되고, Logstash가 `.env`의 external Kafka bootstrap server로 Kafka producer를 생성하는지 확인합니다.

## Kafka Connect

```sh
curl -s http://localhost:8083/connectors | jq .
curl -s http://localhost:8083/connectors/nginx-s3-sink-connector/status | jq .
curl -s http://localhost:8083/connectors/mysql-source-connector/status | jq .
curl -s http://localhost:8083/connectors/mysql-cdc-s3-sink-connector/status | jq .
```

세 connector가 모두 등록되어야 합니다. Kafka와 Cloud Storage credential이 올바르면 task state가 `RUNNING`이어야 합니다.

## Cloud Storage

```sh
gcloud storage ls -r "gs://$BUCKET_NAME/$S3_TOPICS_DIR/nginx-json-logs/nginx-topic/partition=0/*"
gcloud storage ls -r "gs://$BUCKET_NAME/$S3_TOPICS_DIR/mysql-cdc/mysql-server.shopdb.cart_logs/partition=0/*"
gcloud storage ls -r "gs://$BUCKET_NAME/$S3_TOPICS_DIR/mysql-cdc/mysql-server.shopdb.orders/partition=0/*"
```

BigQuery external table URI도 같은 prefix를 바라봅니다. BigQuery URI에는 recursive `**`가 아니라 한 개의 `*` wildcard를 사용합니다.

## BigQuery

`sql/01_create_external_tables.sql`과 `sql/02_create_views.sql`를 실행한 뒤 다음 smoke query를 실행합니다. Dataset 변수명은 README와 동일하게 `BIGQUERY_DATASET`을 사용합니다.

```sh
bq query --use_legacy_sql=false "SELECT COUNT(*) AS nginx_rows FROM \`$PROJECT_ID.$BIGQUERY_DATASET.nginx_logs_view\`"
bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.$BIGQUERY_DATASET.vw_endpoint_error_rate\` LIMIT 10;"
bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.$BIGQUERY_DATASET.vw_cart_event_summary\` LIMIT 10;"
bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.$BIGQUERY_DATASET.vw_product_interest_cart_summary\` LIMIT 10;"
```

## Helper script

```sh
scripts/validate.sh
```

이 script는 local check를 실행하고, 필요한 CLI와 `.env` 값이 있을 때 Cloud Storage와 BigQuery check를 선택적으로 실행합니다.
