#!/bin/sh
set -eu

: "${MYSQL_HOST:=mysql}"

gunicorn \
  --workers "${GUNICORN_WORKERS:-3}" \
  --threads "${GUNICORN_THREADS:-4}" \
  -b 127.0.0.1:8080 \
  app:app &

nginx -g "daemon off;"
