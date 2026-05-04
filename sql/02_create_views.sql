-- 실행 전에 PROJECT_ID를 실제 값으로 교체합니다.

CREATE OR REPLACE VIEW `PROJECT_ID.futureschole_logs.nginx_logs_view` AS
SELECT
  COALESCE(
    SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', timestamp),
    SAFE.PARSE_TIMESTAMP('%d/%b/%Y:%H:%M:%S %z', timestamp)
  ) AS event_ts,
  remote_addr,
  request,
  status,
  body_bytes_sent,
  http_referer,
  session_id,
  user_id,
  request_time,
  upstream_response_time,
  endpoint,
  method,
  query_params,
  CAST(product_id AS STRING) AS product_id,
  host
FROM `PROJECT_ID.futureschole_logs.nginx_logs_ext`;

CREATE OR REPLACE VIEW `PROJECT_ID.futureschole_logs.orders_view` AS
SELECT
  order_id,
  user_id,
  session_id,
  CAST(product_id AS STRING) AS product_id,
  price,
  quantity,
  TIMESTAMP_MICROS(order_time) AS order_ts,
  price * quantity AS revenue,
  __op,
  __table,
  __deleted
FROM `PROJECT_ID.futureschole_logs.orders_cdc_ext`
WHERE COALESCE(__deleted, 'false') != 'true';

CREATE OR REPLACE VIEW `PROJECT_ID.futureschole_logs.cart_logs_view` AS
SELECT
  log_id,
  cart_id,
  session_id,
  user_id,
  CAST(product_id AS STRING) AS product_id,
  old_quantity,
  new_quantity,
  price,
  event_type,
  CASE
    WHEN event_time IS NULL THEN NULL
    WHEN LENGTH(CAST(event_time AS STRING)) >= 16 THEN TIMESTAMP_MICROS(event_time)
    ELSE TIMESTAMP_MILLIS(event_time)
  END AS event_ts,
  __op,
  __table,
  __deleted
FROM `PROJECT_ID.futureschole_logs.cart_logs_cdc_ext`
WHERE COALESCE(__deleted, 'false') != 'true';

CREATE OR REPLACE VIEW `PROJECT_ID.futureschole_logs.vw_endpoint_error_rate` AS
SELECT
  endpoint,
  COUNT(*) AS total_requests,
  COUNTIF(status >= 400) AS error_requests,
  COUNTIF(status >= 500) AS server_error_requests,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(status >= 400), COUNT(*)), 2) AS error_rate_pct,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(status >= 500), COUNT(*)), 2) AS server_error_rate_pct,
  AVG(request_time) AS avg_request_time
FROM `PROJECT_ID.futureschole_logs.nginx_logs_view`
WHERE endpoint IS NOT NULL
GROUP BY endpoint;

CREATE OR REPLACE VIEW `PROJECT_ID.futureschole_logs.vw_cart_event_summary` AS
WITH normalized AS (
  SELECT
    COALESCE(event_type, 'UNKNOWN') AS cart_event_type,
    session_id,
    user_id,
    price,
    CASE
      WHEN event_type = 'ADDED' THEN GREATEST(
        COALESCE(new_quantity, 0) - COALESCE(old_quantity, 0),
        COALESCE(new_quantity, 0),
        0
      )
      ELSE 0
    END AS added_quantity
  FROM `PROJECT_ID.futureschole_logs.cart_logs_view`
)
SELECT
  cart_event_type,
  COUNT(*) AS event_count,
  COUNT(DISTINCT NULLIF(session_id, '')) AS session_count,
  COUNT(DISTINCT NULLIF(user_id, '')) AS user_count,
  SUM(added_quantity) AS added_quantity,
  SUM(added_quantity * COALESCE(price, 0)) AS estimated_added_value
FROM normalized
GROUP BY cart_event_type;

CREATE OR REPLACE VIEW `PROJECT_ID.futureschole_logs.vw_product_interest_cart_summary` AS
WITH product_views AS (
  SELECT
    CONCAT('product_', CAST(product_id AS STRING)) AS product_label,
    COUNT(*) AS page_view_count,
    COUNT(DISTINCT NULLIF(session_id, '')) AS view_sessions
  FROM `PROJECT_ID.futureschole_logs.nginx_logs_view`
  WHERE endpoint = '/product'
    AND status < 400
    AND product_id IS NOT NULL
    AND product_id != ''
  GROUP BY product_label
),
cart_adds AS (
  SELECT
    CONCAT('product_', CAST(product_id AS STRING)) AS product_label,
    COUNT(*) AS cart_add_events,
    COUNT(DISTINCT NULLIF(session_id, '')) AS cart_add_sessions
  FROM `PROJECT_ID.futureschole_logs.cart_logs_view`
  WHERE event_type = 'ADDED'
    AND product_id IS NOT NULL
    AND product_id != ''
  GROUP BY product_label
)
SELECT
  COALESCE(pv.product_label, ca.product_label) AS product_label,
  COALESCE(pv.page_view_count, 0) AS page_view_count,
  COALESCE(pv.view_sessions, 0) AS view_sessions,
  COALESCE(ca.cart_add_events, 0) AS cart_add_events,
  COALESCE(ca.cart_add_sessions, 0) AS cart_add_sessions,
  ROUND(
    100 * SAFE_DIVIDE(COALESCE(ca.cart_add_sessions, 0), NULLIF(COALESCE(pv.view_sessions, 0), 0)),
    2
  ) AS view_to_cart_rate_pct
FROM product_views pv
FULL OUTER JOIN cart_adds ca USING (product_label);
