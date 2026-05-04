#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== Compose services =="
docker compose config --services

echo "== Compose status =="
docker compose ps -a

echo "== API health =="
curl -fsS http://localhost:8080/health
echo

echo "== Traffic generator logs =="
docker compose logs --tail=50 traffic-generator

echo "== MySQL row counts =="
docker compose exec -T mysql mysql -uadmin -padmin1234 shopdb -e "
SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'sessions', COUNT(*) FROM sessions
UNION ALL SELECT 'cart_logs', COUNT(*) FROM cart_logs
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'reviews', COUNT(*) FROM reviews
UNION ALL SELECT 'search_logs', COUNT(*) FROM search_logs;"

echo "== Filebeat logs =="
docker compose logs --tail=50 filebeat

echo "== Logstash logs =="
docker compose logs --tail=50 logstash

echo "== Kafka Connect connectors =="
if command -v jq >/dev/null 2>&1; then
  curl -fsS http://localhost:8083/connectors | jq .
else
  curl -fsS http://localhost:8083/connectors
  echo
fi

for connector in nginx-s3-sink-connector mysql-source-connector mysql-cdc-s3-sink-connector; do
  echo "== Kafka Connect status: ${connector} =="
  if command -v jq >/dev/null 2>&1; then
    curl -fsS "http://localhost:8083/connectors/${connector}/status" | jq .
  else
    curl -fsS "http://localhost:8083/connectors/${connector}/status"
    echo
  fi
done

read_env_value() {
  local name="$1"

  if [ -n "${!name:-}" ]; then
    printf '%s' "${!name}"
    return
  fi

  if [ -f .env ]; then
    grep -E "^${name}=" .env | tail -n 1 | cut -d= -f2- || true
  fi
}

BUCKET_NAME="$(read_env_value BUCKET_NAME)"
S3_TOPICS_DIR="raw"
PROJECT_ID="$(read_env_value PROJECT_ID)"
BIGQUERY_DATASET="futureschole_logs"

if command -v gcloud >/dev/null 2>&1 && [ -n "$BUCKET_NAME" ] && [ -n "$S3_TOPICS_DIR" ]; then
  echo "== Cloud Storage prefixes =="
  gcloud storage ls -r "gs://${BUCKET_NAME}/${S3_TOPICS_DIR}/nginx-json-logs/nginx-topic/partition=0/*" || true
  gcloud storage ls -r "gs://${BUCKET_NAME}/${S3_TOPICS_DIR}/mysql-cdc/mysql-server.shopdb.cart_logs/partition=0/*" || true
  gcloud storage ls -r "gs://${BUCKET_NAME}/${S3_TOPICS_DIR}/mysql-cdc/mysql-server.shopdb.orders/partition=0/*" || true
else
  echo "== Cloud Storage prefixes skipped: gcloud or .env values missing =="
fi

if command -v bq >/dev/null 2>&1 && [ -n "$PROJECT_ID" ] && [ -n "$BIGQUERY_DATASET" ]; then
  echo "== BigQuery smoke queries =="
  bq query --use_legacy_sql=false "SELECT COUNT(*) AS nginx_rows FROM \`${PROJECT_ID}.${BIGQUERY_DATASET}.nginx_logs_view\`" || true
  bq query --use_legacy_sql=false "SELECT COUNT(*) AS order_rows FROM \`${PROJECT_ID}.${BIGQUERY_DATASET}.orders_view\`" || true
else
  echo "== BigQuery smoke queries skipped: bq or .env values missing =="
fi
