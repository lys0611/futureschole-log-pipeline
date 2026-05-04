# 아키텍처

이 문서는 이벤트 로그 파이프라인의 구성 요소와 데이터 흐름을 설명합니다. 이 프로젝트는 단일 VM에서 Docker Compose로 애플리케이션과 수집 agent를 실행하고, Kafka, Object Storage, 분석, 시각화 계층은 GCP 관리형 서비스를 사용합니다.

현재 구성은 과제 제출과 재현성을 우선한 데모 파이프라인입니다. 운영 환경 전체를 그대로 복제한 구조는 아니지만, 이벤트 생성, 로그 수집, CDC, Kafka 적재, Cloud Storage 저장, BigQuery 분석, Looker Studio 시각화까지 데이터 파이프라인의 핵심 흐름을 end-to-end로 연결했습니다.

---

## 1. 전체 흐름

```text
[VM: Docker Compose]

traffic-generator
  -> api-server Nginx:80
      -> Gunicorn/Flask:8080
          -> mysql:3306

api-server Nginx access log
  -> filebeat
      -> logstash:5044
          -> GCP Managed Kafka: nginx-topic

mysql binlog
  -> kafka-connect mysql-source-connector
      -> GCP Managed Kafka: mysql-server.shopdb.* topics

GCP Managed Kafka topics
  -> kafka-connect nginx-s3-sink-connector
      -> Cloud Storage: raw/nginx-json-logs

  -> kafka-connect mysql-cdc-s3-sink-connector
      -> Cloud Storage: raw/mysql-cdc

Cloud Storage JSON
  -> BigQuery external tables
      -> BigQuery views
          -> Looker Studio dashboard
```

---

## 2. 구성 원칙

| 원칙              | 적용 내용                                                                               |
| --------------- | ----------------------------------------------------------------------------------- |
| 단일 VM 재현성       | 평가자가 Docker Compose로 VM 내부 스택을 한 번에 실행할 수 있게 구성했습니다.                                |
| 관리형 서비스 활용      | Kafka, Cloud Storage, BigQuery, Looker Studio는 GCP 관리형 서비스를 사용했습니다.                 |
| 로그와 비즈니스 데이터 분리 | Nginx access log와 MySQL CDC를 분리해 운영 품질과 비즈니스 상태 변화를 따로 분석할 수 있게 했습니다.               |
| Raw data 보존     | Kafka Connect S3 Sink로 Cloud Storage에 JSON 원본을 남기고, BigQuery external table로 분석합니다. |
| 과제 범위 내 검증성     | 고가용성보다 이벤트 생성 → 저장 → 분석 → 시각화가 재현되는 구조를 우선했습니다.                                     |

---

## 3. VM 내부 컴포넌트

| Service             | 역할                                                                    |
| ------------------- | --------------------------------------------------------------------- |
| `traffic-generator` | FSM 기반 사용자 행동 트래픽을 continuous mode로 생성합니다.                            |
| `api-server`        | Nginx `80`번 port와 Gunicorn/Flask `8080`번 port를 함께 실행합니다.              |
| `mysql`             | 사용자, 상품, 장바구니, 주문, 리뷰, 검색 등 비즈니스 데이터를 저장합니다.                          |
| `filebeat`          | Docker volume에 기록되는 Nginx access log 파일을 tailing합니다.                  |
| `logstash`          | Nginx JSON log를 parsing하고 `nginx-topic`으로 전송합니다.                      |
| `kafka-connect`     | 하나의 Kafka Connect worker에서 Debezium Source와 S3 Sink connector를 실행합니다. |
| `connector-init`    | Kafka Connect REST API가 준비된 뒤 세 connector를 idempotent하게 등록합니다.        |

VM 내부에서는 애플리케이션, 데이터베이스, 로그 수집 agent, Kafka Connect worker를 함께 실행합니다. 이 방식은 과제 평가자가 별도 서버 여러 대를 준비하지 않아도 전체 흐름을 재현할 수 있다는 장점이 있습니다.

---

## 4. 외부 GCP 관리형 서비스

| Service           | 역할                                                                                                    |
| ----------------- | ----------------------------------------------------------------------------------------------------- |
| GCP Managed Kafka | Nginx log topic, Kafka Connect internal topic, Debezium schema history topic, MySQL CDC topic을 저장합니다. |
| Cloud Storage     | Kafka Connect S3 Sink Connector가 기록하는 raw JSON archive 저장소입니다.                                        |
| BigQuery          | Cloud Storage JSON 위에 external table과 view를 만들어 분석 계층을 제공합니다.                                         |
| Looker Studio     | BigQuery view를 기반으로 SQL 집계 결과를 시각화합니다.                                                                |

Kafka를 로컬 Compose에 포함하지 않고 GCP Managed Kafka로 분리한 이유는 메시지 브로커 계층을 애플리케이션 VM과 분리해 클라우드 기반 파이프라인 형태를 유지하기 위해서입니다. 단일 VM의 실행 부담은 줄이고, Kafka topic과 connector 흐름은 실제 관리형 메시징 환경에 가깝게 구성했습니다.

---

## 5. 데이터 흐름

### 5.1 사용자 행동 트래픽

```text
traffic-generator
  -> api-server
  -> MySQL business tables
  -> Nginx access log
```

`traffic-generator`는 단순 random request가 아니라 사용자 상태와 행동 흐름을 기반으로 API 요청을 생성합니다. 비로그인 사용자는 상품 목록, 검색, 카테고리, 상품 상세를 탐색하고, 로그인 사용자는 장바구니, checkout, review, logout 등의 흐름을 수행합니다.

API 서버는 요청을 처리하면서 MySQL에 사용자, 세션, 장바구니, 주문, 리뷰, 검색 데이터를 기록합니다. 동시에 Nginx는 각 HTTP 요청을 access log로 남깁니다.

### 5.2 Nginx 로그 수집

```text
Nginx access log
  -> filebeat
  -> logstash
  -> nginx-topic
  -> Cloud Storage raw/nginx-json-logs
```

Nginx access log는 HTTP 요청 단위의 운영 데이터를 제공합니다. 주요 분석 대상은 endpoint, status, request_time, upstream_response_time, session_id, user_id, product_id입니다.

Filebeat는 Nginx log 파일을 tailing하고, Logstash는 로그를 JSON 형태로 정리해 GCP Managed Kafka의 `nginx-topic`으로 전송합니다. 이후 `nginx-s3-sink-connector`가 해당 topic을 Cloud Storage에 저장합니다.

### 5.3 MySQL CDC 수집

```text
MySQL binlog
  -> Debezium MySQL Source Connector
  -> mysql-server.shopdb.* topics
  -> Cloud Storage raw/mysql-cdc
```

MySQL CDC는 애플리케이션 코드가 직접 이벤트를 별도로 발행하지 않아도 데이터베이스 상태 변경을 추적할 수 있게 합니다. Debezium은 MySQL binlog를 읽어 `mysql-server.shopdb.*` topic에 변경 데이터를 publish합니다.

이 프로젝트에서는 `cart_logs`, `orders` 같은 비즈니스 이벤트성 테이블을 CDC 분석의 주요 대상으로 사용합니다. `mysql-cdc-s3-sink-connector`는 CDC topic을 Cloud Storage의 `raw/mysql-cdc` 경로에 저장합니다.

### 5.4 분석과 시각화

```text
Cloud Storage JSON
  -> BigQuery external tables
  -> BigQuery views
  -> Looker Studio dashboard
```

Cloud Storage에 저장된 JSON은 BigQuery external table로 조회합니다. 별도 적재 job을 만들지 않고도 raw archive 위에서 SQL 분석을 시작할 수 있습니다.

최종 분석 view는 다음 세 가지입니다.

| View                               | 목적                                                        |
| ---------------------------------- | --------------------------------------------------------- |
| `vw_endpoint_error_rate`           | endpoint별 HTTP 오류율을 계산해 운영 품질을 확인합니다.                     |
| `vw_cart_event_summary`            | 장바구니 이벤트 유형별 발생 건수를 집계해 DB 상태 변경을 확인합니다.                  |
| `vw_product_interest_cart_summary` | 상품 조회 session과 장바구니 추가 session을 비교해 관심 행동과 전환 행동을 함께 봅니다. |

---

## 6. Connector 흐름

| Connector                     | Source                               | Sink                                                                         |
| ----------------------------- | ------------------------------------ | ---------------------------------------------------------------------------- |
| `nginx-s3-sink-connector`     | `nginx-topic`                        | `gs://$BUCKET_NAME/raw/nginx-json-logs/nginx-topic/partition=0/*` |
| `mysql-source-connector`      | MySQL binlog                         | `mysql-server.shopdb.*` Kafka topics                                         |
| `mysql-cdc-s3-sink-connector` | `mysql-server.shopdb.*` Kafka topics | `gs://$BUCKET_NAME/raw/mysql-cdc/...`                             |

Connector 등록은 `connector-init` 서비스가 Kafka Connect REST API를 호출해 수행합니다. 이미 connector가 존재하는 경우에도 같은 이름의 connector config를 업데이트할 수 있도록 idempotent하게 구성했습니다.

---

## 7. 로그와 CDC를 분리한 이유

Nginx access log는 요청 경로, 상태 코드, 응답 시간, referer, session ID처럼 서비스 운영 품질과 사용자 요청 흐름을 설명합니다. 반면 MySQL CDC는 장바구니, 주문, 리뷰, 사용자 변경처럼 실제 데이터베이스 상태 변화를 설명합니다.

두 흐름을 하나의 테이블에 섞지 않고 Kafka topic과 Cloud Storage prefix를 분리했습니다. 이 방식은 장애 분석, 장바구니 이벤트 분석, 상품 관심도 분석을 각각 독립적으로 수행할 수 있게 합니다.

예를 들어 `/product` 조회는 Nginx log에서 사용자의 관심 행동으로 확인하고, 장바구니 추가는 MySQL CDC의 `cart_logs`에서 실제 상태 변경으로 확인합니다. 두 데이터를 BigQuery view에서 결합하면 단순 페이지 조회와 실제 장바구니 행동의 차이를 분석할 수 있습니다.

---

## 8. 스키마 설계 관점

MySQL은 비즈니스 상태를 보존하는 저장소로 사용했습니다. 사용자, 상품, 장바구니, 주문, 리뷰, 검색 데이터를 테이블로 나누어 저장해 각 이벤트를 필드 단위로 조회할 수 있게 했습니다.

Nginx access log는 운영 로그로 분리했습니다. HTTP status, endpoint, request_time 같은 필드는 장애 분석과 endpoint별 품질 확인에 적합합니다.

CDC 데이터는 MySQL binlog를 기반으로 생성되므로 애플리케이션이 기록한 상태 변경의 근거 데이터로 사용할 수 있습니다. 이 때문에 장바구니 이벤트 유형별 발생 건수나 상품 조회 후 장바구니 추가 비교 지표에 적합합니다.

---

## 9. 현재 아키텍처 수준과 한계

현재 구조는 단일 VM에서 재현 가능한 과제용 demo pipeline입니다. 이벤트 생성, 로그 수집, CDC, Kafka 적재, Object Storage 저장, BigQuery 분석, Looker Studio 시각화까지 연결되어 있어 데이터 파이프라인의 핵심 흐름을 검증할 수 있습니다.

다만 운영 환경 기준으로는 다음 한계가 있습니다.

| 현재 구성               | 한계                                     |
| ------------------- | -------------------------------------- |
| 단일 Ubuntu VM        | VM 장애 시 전체 VM-local stack이 중단될 수 있습니다. |
| MySQL container     | 운영 DB 수준의 백업, 장애 조치, 권한 분리 구성이 부족합니다.  |
| 수동 GCP 리소스 생성       | 환경 재현성과 변경 이력 관리가 제한됩니다.               |
| `.env` 기반 secret 입력 | secret rotation과 접근 제어가 수동입니다.         |
| 수동 검증 명령            | 배포 전 자동 검증 체계가 부족합니다.                  |
| 기본 로그 확인            | connector task 장애나 지연에 대한 자동 알림은 없습니다. |

---

## 10. 향후 확장 방향

| 현재 구성               | 운영 확장 방향                                          |
| ------------------- | ------------------------------------------------- |
| 단일 Ubuntu VM        | Kubernetes, Managed Instance Group, 또는 서비스별 분리 배포 |
| MySQL container     | Cloud SQL 또는 관리형 MySQL로 전환                        |
| 수동 GCP 리소스 생성       | Terraform 기반 IaC 적용                               |
| `.env` 기반 secret 입력 | Secret Manager 연동                                 |
| 수동 검증 명령            | CI/CD pipeline과 smoke test 자동화                    |
| 기본 로그 확인            | Cloud Monitoring alert, connector task 상태 알림 추가   |
| 6시간 테스트 트래픽 기준 집계   | 장기 적재 후 시간대별 매출, AOV, retention 지표 추가             |

이번 과제에서는 완성도 높은 운영 플랫폼보다 짧은 기간 안에 end-to-end 데이터 흐름을 검증하는 데 집중했습니다. 이후 운영 수준으로 확장한다면 장애 복구, 권한 분리, secret 관리, 배포 자동화, 모니터링 체계를 우선순위로 추가할 계획입니다.
