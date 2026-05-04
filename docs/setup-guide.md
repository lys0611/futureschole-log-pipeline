# GCP 구축 및 실행 가이드

이 문서는 빈 GCP 프로젝트에서 이벤트 로그 파이프라인을 재현하기 위한 구축 절차를 정리합니다. VPC, Subnet, Firewall, VM, Managed Kafka, Cloud Storage, BigQuery dataset을 순서대로 만들고, VM에서 Docker Compose로 파이프라인을 실행합니다.

실행 후 검증 절차는 [`docs/validation.md`](validation.md)를 참고합니다.

---

## 1. 사전 준비

| 항목 | 설명 |
| --- | --- |
| GCP 프로젝트 | 새 프로젝트 또는 기존 프로젝트 |
| 결제 계정 | Compute Engine, Managed Kafka, Cloud Storage, BigQuery 사용을 위해 필요 |
| Cloud Shell 또는 Google Cloud CLI | GCP 리소스 생성 명령 실행 |
| GCP Console | VM 브라우저 SSH 접속 |
| GitHub Public repository | 프로젝트 clone 대상 |

---

## 2. 환경 변수 설정

`Cloud Shell` 또는 `Google Cloud CLI가 설정된 터미널`에서 실행합니다.

```sh
gcloud auth login

export PROJECT_ID="replace-with-gcp-project-id"

# 새 프로젝트를 만들 경우에만 실행합니다.
# 이미 프로젝트가 있으면 생략합니다.
# gcloud projects create "$PROJECT_ID"

gcloud config set project "$PROJECT_ID"
gcloud config set compute/region asia-northeast3
gcloud config set compute/zone asia-northeast3-a
````

* 설정 확인

  ```sh
  gcloud config get-value project
  gcloud config get-value compute/region
  gcloud config get-value compute/zone
  ```

---

## 3. 필요한 API 활성화

```sh
gcloud services enable compute.googleapis.com
gcloud services enable managedkafka.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable bigquery.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable serviceusage.googleapis.com
```

* 활성화 확인

  ```sh
  gcloud services list --enabled \
    --filter="name:(compute.googleapis.com OR managedkafka.googleapis.com OR storage.googleapis.com OR bigquery.googleapis.com OR iam.googleapis.com)" \
    --format="table(config.name)"
  ```

---

## 4. VPC와 Subnet 생성

이 파이프라인은 custom mode VPC 1개와 서울 리전 subnet 1개를 사용합니다. VM과 Managed Kafka를 같은 리전 subnet에 연결해 Kafka를 인터넷에 직접 노출하지 않고 접근합니다.

```sh
gcloud compute networks create futureschole-vpc \
  --subnet-mode=custom

gcloud compute networks subnets create futureschole-subnet-seoul \
  --network=futureschole-vpc \
  --region=asia-northeast3 \
  --range=10.10.0.0/24 \
  --enable-private-ip-google-access
```

* 생성 확인

  ```sh
  gcloud compute networks describe futureschole-vpc

  gcloud compute networks subnets describe futureschole-subnet-seoul \
    --region=asia-northeast3
  ```

---

## 5. Firewall rule 생성

SSH와 API health 확인에 필요한 포트만 허용합니다. `0.0.0.0/0`보다 `본인 공인 IP/32`를 권장합니다.

```sh
export YOUR_PUBLIC_IP="$(curl -s https://api.ipify.org)/32"

gcloud compute firewall-rules create allow-ssh-to-pipeline-vm \
  --network=futureschole-vpc \
  --direction=INGRESS \
  --priority=1000 \
  --allow=tcp:22 \
  --source-ranges="$YOUR_PUBLIC_IP" \
  --target-tags=api-health

gcloud compute firewall-rules create allow-api-health-8080 \
  --network=futureschole-vpc \
  --direction=INGRESS \
  --priority=1000 \
  --allow=tcp:8080 \
  --source-ranges="$YOUR_PUBLIC_IP" \
  --target-tags=api-health
```

---

## 6. Ubuntu VM 생성

```sh
gcloud compute instances create futureschole-pipeline-vm \
  --zone=asia-northeast3-a \
  --machine-type=e2-standard-4 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network=futureschole-vpc \
  --subnet=futureschole-subnet-seoul \
  --tags=api-health
```

* 외부 IP 확인

```sh
gcloud compute instances describe futureschole-pipeline-vm \
  --zone=asia-northeast3-a \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
```

* `.env`에 넣을 값으로 사용할 수 있습니다.

```sh
export VM_EXTERNAL_IP="$(gcloud compute instances describe futureschole-pipeline-vm \
  --zone=asia-northeast3-a \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)")"

echo "$VM_EXTERNAL_IP"
```

---

## 7. GCP Console에서 VM SSH 접속

기본 접속 방법은 GCP Console의 브라우저 SSH입니다.

1. Google Cloud Console에서 **Compute Engine → VM 인스턴스**로 이동합니다.
2. `futureschole-pipeline-vm` 인스턴스의 상태가 `실행 중`인지 확인합니다.
3. 해당 VM 행의 **SSH** 버튼을 클릭합니다.
4. 브라우저 SSH 터미널이 열리면 이후 명령을 VM 안에서 실행합니다.

---

## 8. VM에서 Docker Engine과 Compose plugin 설치

아래 명령은 `VM`에서 실행합니다.

```sh
curl -fsSL \
  https://github.com/lys0611/futureschole-log-pipeline/raw/refs/heads/main/scripts/setup-vm-docker.sh \
  -o install_docker_ubuntu.sh

chmod +x install_docker_ubuntu.sh
./install_docker_ubuntu.sh

newgrp docker

docker --version
docker compose version
```

---

## 9. Managed Kafka cluster 생성

* `Cloud Shell` 또는 `Google Cloud CLI가 설정된 터미널`에서 실행합니다.
* Kafka cluster는 VM과 같은 subnet에 연결합니다. Cluster 생성에는 시간이 걸릴 수 있습니다.

```sh
gcloud managed-kafka clusters create kafka-clu \
  --location=asia-northeast3 \
  --cpu=3 \
  --memory=3GiB \
  --subnets="projects/$PROJECT_ID/regions/asia-northeast3/subnetworks/futureschole-subnet-seoul" \
  --async
```

* Cluster 상태 확인

  ```sh
  gcloud managed-kafka clusters describe kafka-clu \
    --location=asia-northeast3
  ```

`state`가 `ACTIVE`가 되면 다음 단계로 진행합니다.

---

## 10. Kafka client service account와 SASL 값 준비

Kafka client가 Managed Kafka cluster에 접속하려면 client principal에 `roles/managedkafka.client` 권한이 필요합니다. 이 프로젝트는 테스트 편의를 위해 `SASL_SSL` + `PLAIN` 방식으로 접속합니다.

```sh
gcloud iam service-accounts create kafka-client \
  --display-name="Kafka client for event log pipeline"

export KAFKA_CLIENT_SA="kafka-client@$PROJECT_ID.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$KAFKA_CLIENT_SA" \
  --role="roles/managedkafka.client"
```

Service account key를 생성합니다.

```sh
gcloud iam service-accounts keys create kafka-client-key.json \
  --iam-account="$KAFKA_CLIENT_SA"
```

SASL password로 사용할 base64 문자열을 만듭니다.

```sh
base64 -w 0 < kafka-client-key.json > kafka-client-password.txt
```

`.env`에는 다음 값을 입력합니다.

```text
KAFKA_SASL_USERNAME=<kafka-client service account email>
KAFKA_SASL_PASSWORD=<kafka-client-password.txt의 한 줄 값>
```

다음 값은 `.env.example`에 고정 기본값으로 포함되어 있으며, 별도 변경이 필요하지 않습니다.

```text
KAFKA_SECURITY_PROTOCOL=SASL_SSL
KAFKA_SASL_MECHANISM=PLAIN
```

Service account key는 장기 secret입니다. `.env`, `kafka-client-key.json`, `kafka-client-password.txt`는 Git에 커밋하지 않습니다.

---

## 11. Kafka topic 생성

Cluster가 `ACTIVE` 상태가 되면 `nginx-topic`을 생성합니다.

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
  "https://managedkafka.googleapis.com/v1/projects/$PROJECT_ID/locations/asia-northeast3/clusters/kafka-clu/topics?topicId=nginx-topic"
```

Topic 생성 확인:

```sh
curl -s \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://managedkafka.googleapis.com/v1/projects/$PROJECT_ID/locations/asia-northeast3/clusters/kafka-clu/topics/nginx-topic"
```

Kafka Connect 내부 topic과 Debezium schema history topic은 cluster 정책에 따라 자동 생성되거나 수동 생성이 필요할 수 있습니다. Connector 등록 중 topic 생성 권한 또는 auto-create 관련 오류가 발생하면 connector log를 확인한 뒤 필요한 internal topic을 수동으로 생성합니다.

---

## 12. Cloud Storage bucket, service account, HMAC key 생성

Kafka Connect S3 Sink Connector가 Cloud Storage를 S3-compatible endpoint로 사용하도록 bucket과 HMAC key를 준비합니다.

```sh
gcloud storage buckets create "gs://gcp-bucket" \
  --location=asia-northeast3 \
  --uniform-bucket-level-access

gcloud iam service-accounts create kafka-connect-gcs-sink \
  --display-name="Kafka Connect GCS S3-compatible sink"

export GCS_SINK_SA="kafka-connect-gcs-sink@$PROJECT_ID.iam.gserviceaccount.com"

gcloud storage buckets add-iam-policy-binding "gs://gcp-bucket" \
  --member="serviceAccount:$GCS_SINK_SA" \
  --role="roles/storage.objectAdmin"

gcloud storage hmac create "$GCS_SINK_SA"
```

HMAC secret은 생성 시 한 번만 표시됩니다. 출력된 access ID와 secret을 `.env`의 `OBJECT_STORAGE_ACCESS_KEY`, `OBJECT_STORAGE_SECRET_KEY`에 입력합니다.

---

## 13. BigQuery dataset 생성

```sh
bq --location=asia-northeast3 mk --dataset "$PROJECT_ID:futureschole_logs"
```

생성 확인:

```sh
bq ls "$PROJECT_ID:"
```

---

## 14. 프로젝트 clone과 `.env` 작성

아래 명령은 VM SSH 세션에서 실행합니다.

```sh
git clone replace-with-repository-url
cd event-log-pipeline

cp .env.example .env
vi .env
```

평가자 환경에서 반드시 입력해야 하는 값은 다음과 같습니다.

| 변수                          | 설명                                                 |
| --------------------------- | -------------------------------------------------- |
| `PROJECT_ID`                | GCP 프로젝트 ID                                        |
| `VM_EXTERNAL_IP`            | VM external IP                                     |
| `KAFKA_BOOTSTRAP_SERVERS`   | Managed Kafka bootstrap 주소                         |
| `KAFKA_SASL_USERNAME`       | Kafka client service account email                 |
| `KAFKA_SASL_PASSWORD`       | base64-encoded service account key 또는 access token |
| `MYSQL_DEBEZIUM_PASSWORD`   | Debezium replication user password                 |
| `OBJECT_STORAGE_ACCESS_KEY` | Cloud Storage HMAC access ID                       |
| `OBJECT_STORAGE_SECRET_KEY` | Cloud Storage HMAC secret                          |

`.env`는 Git에 커밋하지 않습니다.

---

## 15. Compose 구조 검증

`.env.example`은 placeholder 값으로 Compose 구조만 확인할 때 사용합니다.

```sh
docker compose --env-file .env.example config --services
```

실제 `.env`를 작성한 뒤에는 다음 명령으로 실제 환경변수 기준 구성을 확인합니다.

```sh
docker compose config --services
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

## 16. 파이프라인 실행

```sh
docker compose up --build -d
docker compose ps -a
```

MySQL volume이 이전 설정으로 초기화되어 있거나 Debezium user/binlog 설정을 처음부터 다시 적용해야 할 경우 demo volume을 재생성합니다.

```sh
docker compose down -v --remove-orphans
docker compose up --build -d
```

`docker compose down -v`는 MySQL data volume을 삭제합니다. 기존 test data를 유지해야 하는 경우 실행하지 않습니다.

---

## 17. SQL 실행

Cloud Storage에 Nginx log와 MySQL CDC JSON이 쌓인 뒤 BigQuery SQL을 실행합니다.

SQL 파일의 `PROJECT_ID` placeholder를 실제 값으로 교체한 뒤 실행합니다.

```sh
bq query --use_legacy_sql=false < sql/01_create_external_tables.sql
bq query --use_legacy_sql=false < sql/02_create_views.sql
bq query --use_legacy_sql=false < sql/03_analysis_queries.sql
```

---

## 18. 다음 단계

실행 후 검증은 아래 문서를 따릅니다.

```text
docs/validation.md
```