-- 실행 전에 PROJECT_ID와 BUCKET_NAME을 실제 값으로 교체합니다.
-- BigQuery external table URI는 recursive **가 아니라 한 개의 * wildcard를 사용합니다.

CREATE OR REPLACE EXTERNAL TABLE `PROJECT_ID.futureschole_logs.nginx_logs_ext` (
  timestamp STRING,
  remote_addr STRING,
  request STRING,
  status INT64,
  body_bytes_sent INT64,
  http_referer STRING,
  session_id STRING,
  user_id STRING,
  request_time FLOAT64,
  upstream_response_time FLOAT64,
  endpoint STRING,
  method STRING,
  query_params STRING,
  product_id STRING,
  host STRING
)
OPTIONS (
  format = 'NEWLINE_DELIMITED_JSON',
  uris = ['gs://BUCKET_NAME/raw/nginx-json-logs/nginx-topic/partition=0/*']
);

CREATE OR REPLACE EXTERNAL TABLE `PROJECT_ID.futureschole_logs.cart_logs_cdc_ext` (
  log_id INT64,
  cart_id INT64,
  session_id STRING,
  user_id STRING,
  product_id STRING,
  old_quantity INT64,
  new_quantity INT64,
  price FLOAT64,
  event_type STRING,
  event_time INT64,
  __op STRING,
  __table STRING,
  __deleted STRING
)
OPTIONS (
  format = 'NEWLINE_DELIMITED_JSON',
  uris = ['gs://BUCKET_NAME/raw/mysql-cdc/mysql-server.shopdb.cart_logs/partition=0/*']
);

CREATE OR REPLACE EXTERNAL TABLE `PROJECT_ID.futureschole_logs.orders_cdc_ext` (
  order_id STRING,
  user_id STRING,
  session_id STRING,
  product_id STRING,
  price FLOAT64,
  quantity INT64,
  order_time INT64,
  __op STRING,
  __table STRING,
  __deleted STRING
)
OPTIONS (
  format = 'NEWLINE_DELIMITED_JSON',
  uris = ['gs://BUCKET_NAME/raw/mysql-cdc/mysql-server.shopdb.orders/partition=0/*']
);
