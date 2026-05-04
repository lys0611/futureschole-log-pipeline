#!/bin/sh
set -eu

CONNECT_URL="${CONNECT_URL:-http://kafka-connect:8083}"

for _ in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/connectors" >/dev/null; then
    break
  fi
  sleep 2
done

curl -fsS "${CONNECT_URL}/connectors" >/dev/null

register_connector() {
  connector_name="$1"
  connector_config="$2"

  status="$(curl -sS -o /tmp/register-response -w "%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    --data-binary @"${connector_config}" \
    "${CONNECT_URL}/connectors/${connector_name}/config")"

  case "${status}" in
    200|201)
      cat /tmp/register-response
      ;;
    *)
      cat /tmp/register-response
      exit 1
      ;;
  esac
}

register_connector "nginx-s3-sink-connector" "/connectors/nginx-s3-sink.json"
register_connector "mysql-source-connector" "/connectors/mysql-source.json"
register_connector "mysql-cdc-s3-sink-connector" "/connectors/mysql-cdc-s3-sink.json"
