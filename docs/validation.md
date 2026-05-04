# 검증 절차

이 문서는 `.env`에 실제 GCP/Kafka/Cloud Storage 값을 입력하고 Docker Compose를 시작한 뒤 실행하는 검증 명령을 정리합니다.

기존 검증 환경에서는 runtime pipeline을 테스트했습니다. 다른 GCP 프로젝트에서 최종 live 검증을 하려면 평가자별 `.env`와 GCP 리소스가 준비되어야 합니다.

---

## 1. Compose 구성 확인

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

---

## 2. API health check

```sh
curl -s http://localhost:8080/health
```

예상 응답:

```json
{"status":"ok"}
```

외부에서 확인할 경우 VM external IP를 사용합니다.

```sh
curl -s http://$VM_EXTERNAL_IP:8080/health
```

외부 확인을 위해서는 VPC firewall에서 `tcp:8080`이 허용되어 있어야 합니다.

---

## 3. Traffic generator log 확인

```sh
docker compose logs --tail=100 traffic-generator
```

확인할 내용:

| 항목 | 기준 |
| --- | --- |
| API request 발생 | traffic-generator가 종료되지 않고 요청을 생성 |
| API_BASE_URL | `api-server:80` 기준으로 내부 통신 |
| 에러 반복 여부 | connection refused, timeout 반복이 없어야 함 |

---

## 4. MySQL 데이터 확인

```sh
docker compose exec -T mysql mysql -uadmin -padmin1234 shopdb -e "
SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'sessions', COUNT(*) FROM sessions
UNION ALL SELECT 'cart_logs', COUNT(*) FROM cart_logs
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'reviews', COUNT(*) FROM reviews
UNION ALL SELECT 'search_logs', COUNT(*) FROM search_logs;"
```

정확한 row count는 traffic generator 실행 시간에 따라 달라집니다. 이 쿼리는 API와 traffic-generator가 MySQL 비즈니스 테이블에 데이터를 기록했는지 확인하기 위한 smoke test입니다.

---

## 5. Filebeat와 Logstash 확인

```sh
docker compose logs --tail=100 filebeat
docker compose logs --tail=100 logstash
```

확인할 내용:

| 컴포넌트 | 확인 내용 |
| --- | --- |
| Filebeat | Nginx access log 파일을 읽고 `logstash:5044`로 전송 |
| Logstash | Kafka producer가 생성되고 external Kafka bootstrap server로 전송 |

Logstash log에서 Kafka producer 설정, `Successfully logged in`, `Pipeline started`가 확인되면 Kafka 전송 준비가 된 상태입니다.

---

## 6. Kafka topic sample 확인

Kafka client 설정 파일 `client.properties`는 평가자 환경의 SASL_SSL/PLAIN 값으로 준비해야 합니다.

```sh
kafka-topics \
  --bootstrap-server "$KAFKA_BOOTSTRAP_SERVERS" \
  --command-config client.properties \
  --list

kafka-console-consumer \
  --bootstrap-server "$KAFKA_BOOTSTRAP_SERVERS" \
  --consumer.config client.properties \
  --topic nginx-topic \
  --from-beginning \
  --max-messages 5
```

`nginx-topic`에서 JSON log sample이 확인되면 Nginx log → Filebeat → Logstash → Kafka 흐름이 동작하는 상태입니다.

---

## 7. Kafka Connect connector 상태 확인

```sh
curl -s http://localhost:8083/connectors | jq .

curl -s http://localhost:8083/connectors/nginx-s3-sink-connector/status | jq .
curl -s http://localhost:8083/connectors/mysql-source-connector/status | jq .
curl -s http://localhost:8083/connectors/mysql-cdc-s3-sink-connector/status | jq .
```

세 connector가 모두 등록되어야 합니다. Kafka와 Cloud Storage credential이 올바르면 각 task state가 `RUNNING`이어야 합니다.

| Connector | 정상 기준 |
| --- | --- |
| `nginx-s3-sink-connector` | `nginx-topic` 데이터를 Cloud Storage에 저장 |
| `mysql-source-connector` | MySQL binlog를 읽어 `mysql-server.shopdb.*` topic 생성 |
| `mysql-cdc-s3-sink-connector` | MySQL CDC topic을 Cloud Storage에 저장 |

---

## 8. Cloud Storage 적재 확인

```sh
gcloud storage ls -r "gs://$BUCKET_NAME/raw/nginx-json-logs/nginx-topic/partition=0/*"
gcloud storage ls -r "gs://$BUCKET_NAME/raw/mysql-cdc/mysql-server.shopdb.cart_logs/partition=0/*"
gcloud storage ls -r "gs://$BUCKET_NAME/raw/mysql-cdc/mysql-server.shopdb.orders/partition=0/*"
```

확인 기준:

| Prefix | 의미 |
| --- | --- |
| `raw/nginx-json-logs/nginx-topic/partition=0/*` | Nginx access log가 Kafka S3 Sink를 통해 저장된 결과 |
| `raw/mysql-cdc/mysql-server.shopdb.cart_logs/partition=0/*` | 장바구니 변경 이벤트가 CDC로 저장된 결과 |
| `raw/mysql-cdc/mysql-server.shopdb.orders/partition=0/*` | 주문 이벤트가 CDC로 저장된 결과 |

BigQuery external table URI도 같은 prefix를 바라봅니다. BigQuery URI에는 recursive `**` 대신 한 개의 `*` wildcard를 사용합니다.

---

## 9. BigQuery SQL 실행 확인

SQL 파일을 실행합니다.

```sh
bq query --use_legacy_sql=false < sql/01_create_external_tables.sql
bq query --use_legacy_sql=false < sql/02_create_views.sql
bq query --use_legacy_sql=false < sql/03_analysis_queries.sql
```

실행 후 smoke query를 확인합니다.

```sh
bq query --use_legacy_sql=false "SELECT COUNT(*) AS nginx_rows FROM \`$PROJECT_ID.futureschole_logs.nginx_logs_view\`"

bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.futureschole_logs.vw_endpoint_error_rate\` LIMIT 10;"

bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.futureschole_logs.vw_cart_event_summary\` LIMIT 10;"

bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.futureschole_logs.vw_product_interest_cart_summary\` LIMIT 10;"
```

각 view의 목적:

| View | 확인 목적 |
| --- | --- |
| `nginx_logs_view` | Nginx access log가 BigQuery에서 조회 가능한지 확인 |
| `vw_endpoint_error_rate` | endpoint별 HTTP 오류율 집계 결과 확인 |
| `vw_cart_event_summary` | 장바구니 이벤트 유형별 발생 건수 확인 |
| `vw_product_interest_cart_summary` | 상품 조회 수와 장바구니 추가 수 비교 확인 |

---

## 10. 시각화 증빙 확인

최종 시각화 이미지는 다음 경로에 있습니다.

```text
docs/images/dashboard.png
```

이 이미지는 BigQuery view를 Looker Studio에 연결해 만든 SQL 집계 결과 시각화입니다.

최종 dashboard에는 다음 세 지표가 포함됩니다.

| 차트 | 데이터 소스 |
| --- | --- |
| 엔드포인트별 HTTP 오류율 | `vw_endpoint_error_rate` |
| 장바구니 이벤트 유형별 발생 건수 | `vw_cart_event_summary` |
| 상품별 조회 수와 장바구니 추가 수 | `vw_product_interest_cart_summary` |

---

## 11. Helper script

```sh
scripts/validate.sh
```

이 script는 local service 확인을 실행하고, `gcloud`, `bq`, `.env` 값이 있을 때 Cloud Storage와 BigQuery 확인을 선택적으로 수행합니다.

---

## 12. 문제 발생 시 확인 순서

| 증상 | 확인할 위치 |
| --- | --- |
| API health 실패 | `docker compose ps -a`, `docker compose logs api-server` |
| MySQL CDC topic 미생성 | `mysql` health, `mysql-source-connector` status, Debezium user 권한 |
| Nginx log가 Kafka에 없음 | `filebeat` log, `logstash` log, `nginx-topic` consumer |
| Cloud Storage에 파일 없음 | S3 Sink connector status, HMAC key, bucket IAM |
| BigQuery external table 조회 실패 | Cloud Storage URI, wildcard 형식, JSON schema |
| Looker Studio 차트 오류 | view schema, `product_label` type, 기간 측정기준 설정 |

---

## 13. 정리 기준

모든 항목이 아래 상태이면 파이프라인이 정상 동작한 것으로 봅니다.

| 구간 | 정상 기준 |
| --- | --- |
| API | `/health`가 `{"status":"ok"}` 반환 |
| MySQL | 주요 table row count 증가 |
| Kafka | `nginx-topic`에서 JSON log sample 확인 |
| Kafka Connect | 세 connector와 task가 `RUNNING` |
| Cloud Storage | Nginx log와 MySQL CDC prefix에 JSON 파일 생성 |
| BigQuery | 세 final view 조회 성공 |
| Looker Studio | `docs/images/dashboard.png`에 SQL 집계 결과 시각화 포함 |