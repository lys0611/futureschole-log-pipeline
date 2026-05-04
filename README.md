# 이커머스 이벤트 로그 파이프라인

이 저장소는 Futureschole Platform/Data Engineering 과제를 위한 단일 VM 기반 이벤트 로그 파이프라인입니다. Docker Compose로 `traffic-generator`, `api-server`, `mysql`, `filebeat`, `logstash`, `kafka-connect`를 실행하고, 외부 GCP Managed Kafka와 Cloud Storage, BigQuery, Looker Studio를 사용해 API 요청 로그와 MySQL CDC 데이터를 분석 가능한 형태로 저장합니다.

Nginx access log는 요청 경로, HTTP 상태 코드, 응답 시간처럼 서비스 운영 품질을 보여줍니다. MySQL CDC는 장바구니, 주문, 리뷰, 사용자, 검색처럼 실제 비즈니스 상태 변화를 보여줍니다. 두 데이터를 분리해 수집하면 운영 관점과 비즈니스 관점을 함께 분석할 수 있습니다.

현재 런타임 파이프라인은 원래 검증 환경에서 테스트되었습니다. 다른 GCP 프로젝트에서 최종 live 검증을 하려면 평가자별 GCP 리소스와 실제 `.env` 값이 필요합니다.

## 아키텍처

```text
VM-local Docker Compose
  traffic-generator
        |
        v
  api-server Nginx:80 -> Gunicorn/Flask:8080 -> mysql
        |
        v
  /var/log/nginx/flask_app_access.log
        |
        v
  filebeat -> logstash:5044
        |
        v
External GCP managed services
  GCP Managed Kafka
    - nginx-topic
    - mysql-server.shopdb.*
        ^
        |
VM-local Docker Compose
  kafka-connect:8083
    - nginx-s3-sink-connector: nginx-topic -> Cloud Storage raw/nginx-json-logs
    - mysql-source-connector: MySQL binlog -> mysql-server.shopdb.* topics
    - mysql-cdc-s3-sink-connector: mysql-server.shopdb.* -> Cloud Storage raw/mysql-cdc

External analytics
  Cloud Storage JSON -> BigQuery external tables/views -> Looker Studio dashboard
```

Docker Compose는 VM 내부 컴포넌트만 실행합니다. Kafka, Cloud Storage, BigQuery, Looker Studio는 외부 GCP 관리형 서비스로 사용합니다.

## 평가자가 입력해야 하는 값

| 값 | 용도 | 예시 placeholder |
| --- | --- | --- |
| `PROJECT_ID` | GCP 프로젝트 ID | `my-assignment-project` |
| `REGION` | VPC subnet, Kafka, bucket, BigQuery dataset 리전 | `us-central1` |
| `ZONE` | Compute Engine VM zone | `us-central1-a` |
| `VPC_NAME` | VPC 이름 | `assignment-vpc` |
| `SUBNET_NAME` | Subnet 이름 | `assignment-subnet` |
| `VM_NAME` | Ubuntu VM 이름 | `log-pipeline-vm` |
| `VM_EXTERNAL_IP` | VM 외부 IP | VM 생성 후 입력 |
| `KAFKA_CLUSTER_NAME` | GCP Managed Kafka cluster 이름 | `assignment-kafka` |
| `KAFKA_BOOTSTRAP_SERVERS` | Kafka bootstrap host와 port | cluster 상세 정보에서 확인 |
| `KAFKA_SASL_USERNAME` | Kafka client IAM principal 또는 service account email | client 설정에서 확인 |
| `KAFKA_SASL_PASSWORD` | Kafka SASL password 또는 token | client 설정에서 확인 |
| `BUCKET_NAME` | Cloud Storage bucket 이름 | 전역에서 고유한 bucket 이름 |
| `OBJECT_STORAGE_ACCESS_KEY` | Cloud Storage HMAC access ID | HMAC 생성 결과 |
| `OBJECT_STORAGE_SECRET_KEY` | Cloud Storage HMAC secret | HMAC 생성 시 한 번만 표시 |
| `BIGQUERY_DATASET` | BigQuery dataset 이름 | `log_pipeline` |
| `LOOKER_STUDIO_REPORT_URL` 또는 screenshot path | 최종 시각화 증빙 | `docs/images/dashboard.png` |

`.env`에는 실제 접속 정보와 secret이 들어가므로 Git에 커밋하지 않습니다. `.env.example`은 placeholder만 유지합니다.

## 빈 GCP 프로젝트에서 시작하기

아래 절차는 VPC, subnet, VM, Kafka, bucket, BigQuery dataset이 없는 GCP 프로젝트에서 시작하는 기준입니다. Cloud Shell 또는 Google Cloud CLI가 설치된 로컬 터미널에서 실행합니다.

### 1. gcloud 인증과 기본 설정

```sh
gcloud auth login

export PROJECT_ID="replace-with-gcp-project-id"
export REGION="replace-with-region"
export ZONE="replace-with-zone"
export VPC_NAME="replace-with-vpc-name"
export SUBNET_NAME="replace-with-subnet-name"
export VM_NAME="replace-with-vm-name"
export KAFKA_CLUSTER_NAME="replace-with-managed-kafka-cluster-name"
export BUCKET_NAME="replace-with-globally-unique-bucket-name"
export BIGQUERY_DATASET="replace-with-bigquery-dataset"

gcloud projects create "$PROJECT_ID"
gcloud config set project "$PROJECT_ID"
gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"
```

이미 프로젝트가 있으면 `gcloud projects create`는 생략하고 `gcloud config set project "$PROJECT_ID"`부터 실행합니다.

### 2. 필요한 API 활성화

```sh
gcloud services enable compute.googleapis.com
gcloud services enable managedkafka.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable bigquery.googleapis.com
gcloud services enable iam.googleapis.com
```

### 3. VPC와 subnet 생성

```sh
gcloud compute networks create "$VPC_NAME" --subnet-mode=custom

gcloud compute networks subnets create "$SUBNET_NAME" \
  --network="$VPC_NAME" \
  --region="$REGION" \
  --range=10.10.0.0/24
```

### 4. 방화벽 규칙 생성

SSH 접속을 위해 `22`번 포트를 열고, API health check를 외부에서 확인해야 하는 경우에만 `8080` 포트를 제한된 IP 범위로 엽니다.

```sh
gcloud compute firewall-rules create allow-ssh \
  --network="$VPC_NAME" \
  --allow=tcp:22 \
  --source-ranges=0.0.0.0/0

gcloud compute firewall-rules create allow-api-health-8080 \
  --network="$VPC_NAME" \
  --allow=tcp:8080 \
  --source-ranges=replace-with-your-ip-cidr
```

### 5. Ubuntu VM 생성과 접속

```sh
gcloud compute instances create "$VM_NAME" \
  --zone="$ZONE" \
  --machine-type=e2-standard-4 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network="$VPC_NAME" \
  --subnet="$SUBNET_NAME" \
  --tags=api-health

gcloud compute ssh "$VM_NAME" --zone "$ZONE"
```

이후 명령은 VM SSH 세션에서 실행합니다.

### 6. Docker Engine과 Docker Compose plugin 설치

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
newgrp docker

docker --version
docker compose version
```

### 7. GCP Managed Kafka cluster와 topic 생성

Kafka cluster는 subnet에 연결해 생성합니다. Cluster 생성은 보통 20-30분 정도 걸릴 수 있습니다.

```sh
gcloud managed-kafka clusters create "$KAFKA_CLUSTER_NAME" \
  --location="$REGION" \
  --cpu=3 \
  --memory=3GiB \
  --subnets="projects/$PROJECT_ID/regions/$REGION/subnetworks/$SUBNET_NAME" \
  --async
```

Cluster가 active 상태가 되면 `nginx-topic`을 생성합니다. Console을 사용해도 되고, Managed Kafka API를 사용할 수도 있습니다.

```sh
cat > request.json <<'JSON'
{
  "partitionCount": 1,
  "replicationFactor": 3
}
JSON

curl -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d @request.json \
  "https://managedkafka.googleapis.com/v1/projects/$PROJECT_ID/locations/$REGION/clusters/$KAFKA_CLUSTER_NAME/topics?topicId=nginx-topic"
```

Kafka Connect 내부 topic과 Debezium schema history topic은 cluster 정책에 따라 auto-create를 허용하거나 수동으로 생성합니다.

```text
connect-configs-nginx-s3
connect-offsets-nginx-s3
connect-statuses-nginx-s3
schema-changes.mysql-server
mysql-server.shopdb.cart
mysql-server.shopdb.cart_logs
mysql-server.shopdb.orders
mysql-server.shopdb.products
mysql-server.shopdb.push_messages
mysql-server.shopdb.reviews
mysql-server.shopdb.search_logs
mysql-server.shopdb.sessions
mysql-server.shopdb.users
mysql-server.shopdb.users_logs
```

Kafka client용 service account 또는 IAM principal을 준비하고 Managed Kafka client 권한과 필요한 ACL을 부여합니다. 이 저장소는 GCP Managed Kafka SASL client 접속을 다음 값으로 가정합니다.

```text
KAFKA_SECURITY_PROTOCOL=SASL_SSL
KAFKA_SASL_MECHANISM=PLAIN
```

### 8. Cloud Storage bucket, service account, HMAC key 생성

Kafka Connect S3 Sink Connector가 Cloud Storage를 S3-compatible endpoint로 사용하도록 bucket과 HMAC key를 준비합니다.

```sh
gcloud storage buckets create "gs://$BUCKET_NAME" \
  --location="$REGION" \
  --uniform-bucket-level-access

gcloud iam service-accounts create kafka-connect-gcs-sink \
  --display-name="Kafka Connect GCS S3-compatible sink"

export GCS_SINK_SA="kafka-connect-gcs-sink@$PROJECT_ID.iam.gserviceaccount.com"

gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
  --member="serviceAccount:$GCS_SINK_SA" \
  --role="roles/storage.objectAdmin"

gcloud storage hmac create "$GCS_SINK_SA"
```

HMAC secret은 생성 시 한 번만 표시됩니다. `OBJECT_STORAGE_ACCESS_KEY`, `OBJECT_STORAGE_SECRET_KEY`에 입력하고 Git에는 커밋하지 않습니다.

### 9. BigQuery dataset 생성

```sh
bq --location="$REGION" mk --dataset "$PROJECT_ID:$BIGQUERY_DATASET"
```

### 10. 저장소 clone과 환경변수 설정

```sh
git clone replace-with-repository-url
cd event-log-pipeline
cp .env.example .env
```

`.env`를 열어 평가자 환경의 실제 값을 입력합니다.

```sh
vi .env
```

`KAFKA_BOOTSTRAP_SERVERS`, `LOGSTASH_KAFKA_ENDPOINT`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`, `BUCKET_NAME`, `OBJECT_STORAGE_ACCESS_KEY`, `OBJECT_STORAGE_SECRET_KEY`, `BIGQUERY_DATASET`은 반드시 실제 값으로 교체해야 합니다.

### 11. 구조 검증과 실행

`docker compose --env-file .env.example config --services`는 placeholder 값을 사용해 Compose 구조만 확인하는 명령입니다.

```sh
docker compose --env-file .env.example config --services
```

실제 `.env`를 입력한 뒤에는 다음 명령으로 실제 환경변수 기준 구성을 확인하고 실행합니다.

```sh
docker compose config --services
docker compose up --build -d
docker compose ps -a
```

MySQL volume을 과거 설정으로 초기화한 적이 있다면 demo volume을 재생성합니다.

```sh
docker compose down -v --remove-orphans
docker compose up --build -d
```

## 과제 요구사항 매핑

| 과제 단계 | 구현 내용 |
| --- | --- |
| Step 1 이벤트 생성기 | `traffic-generator` service가 `api-server:80`으로 FSM 기반 트래픽을 생성합니다. |
| Step 2 구조화 저장 | MySQL business table, Nginx JSON access log, external Kafka topic, Cloud Storage JSON archive를 사용합니다. |
| Step 3 분석 query | `sql/01_create_external_tables.sql`, `sql/02_create_views.sql`, `sql/03_analysis_queries.sql`에서 BigQuery external table과 view, 분석 query를 제공합니다. |
| Step 4 Docker Compose 실행 | `docker compose up --build -d`로 app, DB, log pipeline, connector registration을 함께 실행합니다. |
| Step 5 시각화 | `docs/images/dashboard.png`에 최종 SQL aggregation 시각화 증빙을 제공합니다. |

## 저장소 구조

```text
README.md
docker-compose.yml
.env.example
.gitignore
services/
  api-server/
  traffic-generator/
infra/
  mysql/
    init/
    conf.d/
  filebeat/
  logstash/pipeline/
  kafka-connect/
sql/
docs/images/dashboard.png
docs/architecture.md
docs/validation.md
scripts/validate.sh
```

| 경로 | 설명 |
| --- | --- |
| `docker-compose.yml` | VM-local service와 volume을 정의합니다. |
| `services/api-server/` | Nginx, Gunicorn, Flask API container build context입니다. |
| `services/traffic-generator/` | FSM 기반 traffic generator 구현과 설정입니다. |
| `infra/mysql/init/init.sql` | MySQL schema와 seed data입니다. |
| `infra/mysql/init/02-debezium-user.sh` | MySQL 초기화 시 Debezium replication user를 생성합니다. |
| `infra/mysql/conf.d/cdc.cnf` | Debezium CDC를 위한 MySQL binlog 설정입니다. |
| `infra/filebeat/filebeat.yml` | Nginx access log를 읽어 Logstash로 전송합니다. |
| `infra/logstash/pipeline/logs-to-kafka.conf` | Nginx JSON log를 parsing하고 `nginx-topic`으로 전송합니다. |
| `infra/kafka-connect/` | Kafka Connect image, connector config, connector registration script입니다. |
| `sql/` | BigQuery external table, view, analysis query SQL입니다. |
| `docs/` | 아키텍처, 검증 절차, 대시보드 이미지 문서입니다. |

## 환경변수

`.env`는 local-only 파일이며 Git에 커밋하지 않습니다. `.env.example`을 복사한 뒤 placeholder를 실제 값으로 교체합니다.

| 변수 | 목적 | 사용 위치 | 예시 placeholder |
| --- | --- | --- | --- |
| `PROJECT_ID` | GCP project ID와 SQL placeholder 교체 | README, SQL | `replace-with-gcp-project-id` |
| `REGION` | GCP region | README, GCP commands | `replace-with-region` |
| `ZONE` | VM zone | README, GCP commands | `replace-with-zone` |
| `VPC_NAME` | VPC network 이름 | README, GCP commands | `replace-with-vpc-name` |
| `SUBNET_NAME` | Subnet 이름 | README, GCP commands | `replace-with-subnet-name` |
| `VM_NAME` | VM instance 이름 | README, GCP commands | `replace-with-vm-name` |
| `VM_EXTERNAL_IP` | VM external IP | README | `replace-with-vm-external-ip` |
| `KAFKA_CLUSTER_NAME` | Managed Kafka cluster 이름 | README | `replace-with-managed-kafka-cluster-name` |
| `KAFKA_BOOTSTRAP_SERVERS` | External Kafka bootstrap servers | traffic-generator env, Kafka Connect | `replace-with-managed-kafka-bootstrap-host:9092` |
| `LOGSTASH_KAFKA_ENDPOINT` | Logstash Kafka bootstrap servers | Logstash | `replace-with-managed-kafka-bootstrap-host:9092` |
| `KAFKA_SECURITY_PROTOCOL` | Kafka security protocol | Logstash, Kafka Connect | `SASL_SSL` |
| `KAFKA_SASL_MECHANISM` | Kafka SASL mechanism | Logstash, Kafka Connect | `PLAIN` |
| `KAFKA_SASL_USERNAME` | Kafka SASL principal | Logstash, Kafka Connect | `replace-with-kafka-client-service-account-email` |
| `KAFKA_SASL_PASSWORD` | Kafka SASL password/token | Logstash, Kafka Connect | `replace-with-kafka-sasl-password` |
| `MYSQL_DEBEZIUM_USER` | MySQL replication user | MySQL init, Debezium connector | `debezium` |
| `MYSQL_DEBEZIUM_PASSWORD` | MySQL replication password | MySQL init, Debezium connector | `replace-with-local-debezium-password` |
| `BUCKET_NAME` | Cloud Storage bucket | Kafka Connect S3 sinks, validation | `replace-with-gcs-bucket-name` |
| `OBJECT_STORAGE_ENDPOINT` | S3-compatible endpoint | Kafka Connect S3 sinks | `https://storage.googleapis.com` |
| `OBJECT_STORAGE_REGION` | S3 connector region setting | Kafka Connect S3 sinks | `auto` |
| `OBJECT_STORAGE_ACCESS_KEY` | Cloud Storage HMAC access ID | Kafka Connect S3 sinks | `replace-with-gcs-hmac-access-id` |
| `OBJECT_STORAGE_SECRET_KEY` | Cloud Storage HMAC secret | Kafka Connect S3 sinks | `replace-with-gcs-hmac-secret` |
| `S3_TOPICS_DIR` | Sink output root prefix | Kafka Connect S3 sinks, SQL | `raw` |
| `BIGQUERY_DATASET` | BigQuery dataset 이름 | README, SQL | `replace-with-bigquery-dataset` |
| `LOOKER_STUDIO_REPORT_URL` | Dashboard URL 또는 screenshot path | README | `replace-with-report-url-or-docs/images/dashboard.png` |

## Traffic generator 동작

`services/traffic-generator/traffic_generator.py`는 `traffic-generator` service에서 continuous mode로 실행됩니다. 설정은 `services/traffic-generator/config.py`와 `services/traffic-generator/config.yml`에서 읽습니다.

- 최상위 상태는 `Anon_NotRegistered`, `Anon_Registered`, `Logged_In`, `Logged_Out`, `Unregistered`, `Done`을 사용합니다.
- Anonymous user는 `/`, `/products`, `/product?id=...`, `/categories`, `/category?name=...`, `/search?query=...`, `/error`를 탐색합니다.
- Registered/logged-in user는 상품 탐색, 장바구니 추가/삭제, checkout, review 작성, logout, user 삭제 흐름을 수행합니다.
- API에서 product와 category를 조회해 category-to-product index를 만들고, gender/age preference weight를 사용해 상품 선택을 편향시킵니다.
- Cart count, search count, page depth, session duration, idle time 같은 session context를 전이에 반영합니다.
- 요청 사이에는 random sleep이 들어가며, light/normal/heavy traffic pattern을 순환합니다.
- 가능한 경우 `Referer`를 포함하고, 로그인 요청에는 `X-User-Id`를 포함합니다.

단순 random API 호출보다 session 상태, 선호도, referer, cart context, 목표 지향적 전이를 반영하기 때문에 실제 사용자 행동과 유사한 로그를 생성합니다. 다만 과제용 generator이므로 production traffic distribution 전체를 모델링하지는 않습니다.

## 검증 명령어

### API health check

```sh
curl -s http://localhost:8080/health
```

### Traffic generator log

```sh
docker compose logs --tail=100 traffic-generator
```

### MySQL row count

```sh
docker compose exec -T mysql mysql -uadmin -padmin1234 shopdb -e "
SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'sessions', COUNT(*) FROM sessions
UNION ALL SELECT 'cart_logs', COUNT(*) FROM cart_logs
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'reviews', COUNT(*) FROM reviews
UNION ALL SELECT 'search_logs', COUNT(*) FROM search_logs;"
```

### Filebeat와 Logstash

```sh
docker compose logs --tail=100 filebeat
docker compose logs --tail=100 logstash
```

### Kafka topic과 sample message

Cloud Kafka client 설정 파일 `client.properties`는 평가자 환경의 SASL_SSL/PLAIN 값으로 준비합니다.

```sh
kafka-topics --bootstrap-server "$KAFKA_BOOTSTRAP_SERVERS" --command-config client.properties --list
kafka-console-consumer --bootstrap-server "$KAFKA_BOOTSTRAP_SERVERS" --consumer.config client.properties --topic nginx-topic --from-beginning --max-messages 5
```

### Kafka Connect connector 상태

```sh
curl -s http://localhost:8083/connectors | jq .
curl -s http://localhost:8083/connectors/nginx-s3-sink-connector/status | jq .
curl -s http://localhost:8083/connectors/mysql-source-connector/status | jq .
curl -s http://localhost:8083/connectors/mysql-cdc-s3-sink-connector/status | jq .
```

### Cloud Storage prefix 확인

```sh
gcloud storage ls -r "gs://$BUCKET_NAME/$S3_TOPICS_DIR/nginx-json-logs/nginx-topic/partition=0/*"
gcloud storage ls -r "gs://$BUCKET_NAME/$S3_TOPICS_DIR/mysql-cdc/mysql-server.shopdb.cart_logs/partition=0/*"
gcloud storage ls -r "gs://$BUCKET_NAME/$S3_TOPICS_DIR/mysql-cdc/mysql-server.shopdb.orders/partition=0/*"
```

### BigQuery smoke query

SQL 파일을 실행한 뒤 확인합니다.

```sh
bq query --use_legacy_sql=false "SELECT COUNT(*) AS nginx_rows FROM \`$PROJECT_ID.$BIGQUERY_DATASET.nginx_logs_view\`"
bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.$BIGQUERY_DATASET.vw_endpoint_error_rate\` LIMIT 10"
bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.$BIGQUERY_DATASET.vw_cart_event_summary\` LIMIT 10"
bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.$BIGQUERY_DATASET.vw_product_interest_cart_summary\` LIMIT 10"
```

### Helper script

```sh
scripts/validate.sh
```

이 script는 local service 확인을 실행하고, `gcloud`, `bq`, `.env` 값이 있을 때 Cloud Storage와 BigQuery 확인을 선택적으로 수행합니다.

## 스키마와 데이터 설계

MySQL은 비즈니스 도메인 데이터를 정규화된 table로 저장합니다.

| Table | 역할 |
| --- | --- |
| `users` | gender, age, update timestamp를 포함한 user profile |
| `sessions` | user session lifecycle |
| `products` | price와 category를 포함한 product catalog |
| `cart` | 현재 cart state |
| `cart_logs` | `ADDED`, `UPDATED`, `REMOVED`, `CHECKED_OUT` cart state-change history |
| `orders` | checkout transaction, quantity, price, `order_time` |
| `reviews` | product review event |
| `search_logs` | search behavior |
| `push_messages` | JSON payload 저장 경로로 유지 |

Nginx access log는 request behavior와 operational quality를 분석하기 위한 별도 event stream입니다. 주요 field는 다음과 같습니다.

```text
timestamp, remote_addr, request, status, body_bytes_sent, http_referer,
session_id, user_id, request_time, upstream_response_time, endpoint,
method, query_params, product_id, host
```

MySQL CDC는 Debezium이 MySQL binlog를 읽어 `mysql-server.shopdb.*` topic에 flattened JSON record로 publish합니다. `ExtractNewRecordState`를 사용해 BigQuery에서 row-shaped JSON처럼 조회할 수 있게 했습니다.

이 설계는 운영 로그와 비즈니스 상태 변화를 같은 저장소에 억지로 합치지 않습니다. Nginx 로그는 HTTP endpoint 품질과 request behavior를 빠르게 집계하는 데 적합하고, MySQL table과 CDC는 주문·장바구니 같은 상태 변경의 근거 데이터로 적합합니다. 두 흐름을 Kafka와 Cloud Storage에서 분리해 보관해 장애 분석, 상품 관심도 분석, DB 변경 추적을 독립적으로 수행할 수 있게 했습니다.

## SQL 분석

다음 순서로 SQL을 실행합니다. 실행 전 `PROJECT_ID`, `BIGQUERY_DATASET`, `BUCKET_NAME`, `S3_TOPICS_DIR` placeholder를 실제 값으로 교체합니다.

```sh
bq query --use_legacy_sql=false < sql/01_create_external_tables.sql
bq query --use_legacy_sql=false < sql/02_create_views.sql
bq query --use_legacy_sql=false < sql/03_analysis_queries.sql
```

SQL 파일은 다음 객체를 생성하거나 조회합니다.

- `raw/nginx-json-logs/nginx-topic/partition=0/*` 경로의 Nginx external table
- `raw/mysql-cdc/mysql-server.shopdb.cart_logs/partition=0/*` 경로의 `cart_logs` CDC external table
- `raw/mysql-cdc/mysql-server.shopdb.orders/partition=0/*` 경로의 `orders` CDC external table
- 16자리 microsecond epoch인 `order_time`에 `TIMESTAMP_MICROS`를 적용한 `orders_view`
- `server_error_rate_pct`, `error_rate_pct`를 제공하는 `vw_endpoint_error_rate`
- `cart_event_type`별 event count를 제공하는 `vw_cart_event_summary`
- raw `product_id` 대신 `product_116` 형식의 `product_label`을 사용하는 `vw_product_interest_cart_summary`

BigQuery external table URI는 recursive `**`가 아니라 단일 `*` wildcard를 사용합니다.

## 시각화

최종 SQL aggregation 시각화 증빙은 `docs/images/dashboard.png`입니다. 이 screenshot은 과제 Step 5의 SQL aggregation result visualization 요구사항을 충족합니다.

![최종 Looker Studio 대시보드](docs/images/dashboard.png)

최종 dashboard는 약 6시간 동안 생성한 테스트 트래픽을 기준으로 장기 time-series revenue/AOV보다 안정적인 aggregate chart를 사용합니다.

### Chart 1: 엔드포인트별 HTTP 오류율

- 차트 유형: 막대형 차트
- 데이터 소스: `vw_endpoint_error_rate`
- 측정기준: `endpoint`
- 측정항목: `server_error_rate_pct`, `error_rate_pct`
- 정렬: `server_error_rate_pct` 내림차순
- 기간 측정기준: 없음

### Chart 2: 장바구니 이벤트 유형별 발생 건수

- 차트 유형: 막대형 차트
- 데이터 소스: `vw_cart_event_summary`
- 측정기준: `cart_event_type`
- 측정항목: `event_count`
- 정렬: `event_count` 내림차순
- 기간 측정기준: 없음

### Chart 3: 상품별 조회 수와 장바구니 추가 수

- 차트 유형: 표
- 데이터 소스: `vw_product_interest_cart_summary`
- 측정기준: `product_label`
- 측정항목: `view_sessions`, `cart_add_sessions`, `view_to_cart_rate_pct`
- 정렬: `view_sessions` 내림차순
- 선택 필터: `view_sessions >= 3`
- 기간 측정기준: 없음
- 데이터 혼합: 사용 안 함

## 구현하면서 고민한 점

- Nginx log와 MySQL CDC를 분리했습니다. HTTP request 품질과 사용자 행동은 Nginx log가 잘 설명하고, 주문·장바구니 같은 비즈니스 상태 변경은 MySQL CDC가 더 정확한 근거를 제공합니다.
- Local Kafka를 Compose에 넣지 않고 external GCP Managed Kafka를 사용했습니다. 과제용 단일 VM stack은 가볍게 유지하고, message broker는 관리형 서비스로 분리해 cloud infrastructure 구성 역량을 보여주기 위한 선택입니다.
- Cloud Storage와 BigQuery External Table을 사용했습니다. Raw JSON archive를 먼저 보존하면 재처리와 감사가 가능하고, BigQuery는 별도 적재 job 없이 external table과 view로 분석을 시작할 수 있습니다.
- Debezium MySQL connector는 MySQL binlog 기반 CDC를 사용합니다. Application code를 수정하지 않고 database state-change event를 Kafka topic으로 전달할 수 있기 때문입니다.
- 약 6시간 분량의 테스트 트래픽에서는 장기 매출 추세나 AOV time-series보다 endpoint error rate, cart event count, product interest/cart add 비교 같은 aggregate metric이 더 안정적입니다.
- `infra/mysql/init/02-debezium-user.sh`는 `set -u`를 사용하지 않습니다. MySQL official entrypoint가 `.sh` init script를 source하기 때문에 shell option이 entrypoint에 누수될 수 있습니다.
- BigQuery GCS URI는 `**`가 아니라 한 개의 `*` wildcard를 사용합니다. BigQuery external table URI 제약을 맞추기 위한 결정입니다.
- `orders.order_time`은 16자리 epoch microseconds이므로 `TIMESTAMP_MICROS`를 사용합니다.
- `product_id`는 BI 도구에서 날짜나 숫자로 오인될 수 있어 최종 dashboard dimension은 `product_label` 문자열을 사용합니다.

## 한계와 다음 단계

- GCP resource 생성은 수동 절차로 진행합니다.
- 이 구성은 단일 VM demo이며 production high availability 구성이 아닙니다.
- Kafka topic 생성과 ACL은 평가자 조직의 GCP 정책에 따라 조정이 필요할 수 있습니다.
- 향후 개선 사항은 Terraform, CI/CD, managed database, monitoring alert, Kubernetes manifest, secret manager 연동입니다.

## 참고 문서

- [GCP Managed Kafka cluster creation](https://docs.cloud.google.com/managed-service-for-apache-kafka/docs/create-cluster)
- [GCP Managed Kafka topic creation](https://docs.cloud.google.com/managed-service-for-apache-kafka/docs/create-topic)
- [GCP Managed Kafka SASL authentication](https://cloud.google.com/managed-service-for-apache-kafka/docs/authentication-kafka)
- [Cloud Storage HMAC key creation](https://cloud.google.com/sdk/gcloud/reference/storage/hmac/create)
