#!/bin/sh
set -eu

CONNECT_URL="${CONNECT_URL:-http://kafka-connect:8083}"
CONNECTOR_NAME="nginx-s3-sink-connector"
CONNECTOR_CONFIG="/connectors/nginx-s3-sink.json"

for _ in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/connectors" >/dev/null; then
    break
  fi
  sleep 2
done

curl -fsS "${CONNECT_URL}/connectors" >/dev/null

status="$(curl -sS -o /tmp/register-response -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  --data-binary @"${CONNECTOR_CONFIG}" \
  "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/config")"

case "${status}" in
  200|201)
    cat /tmp/register-response
    ;;
  *)
    cat /tmp/register-response
    exit 1
    ;;
esac
