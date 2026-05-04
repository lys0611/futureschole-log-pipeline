-- 실행 전에 PROJECT_ID를 실제 값으로 교체합니다.

-- Nginx log chart: endpoint별 HTTP error rate를 확인합니다.
SELECT
  endpoint,
  total_requests,
  error_requests,
  server_error_requests,
  error_rate_pct,
  server_error_rate_pct,
  avg_request_time
FROM `PROJECT_ID.futureschole_logs.vw_endpoint_error_rate`
ORDER BY server_error_rate_pct DESC, error_rate_pct DESC, total_requests DESC;

-- MySQL CDC chart: cart event type별 event count를 확인합니다.
SELECT
  cart_event_type,
  event_count,
  session_count,
  user_count,
  added_quantity,
  estimated_added_value
FROM `PROJECT_ID.futureschole_logs.vw_cart_event_summary`
ORDER BY event_count DESC, cart_event_type;

-- Nginx + MySQL CDC chart: product view와 cart add를 비교합니다.
SELECT
  product_label,
  page_view_count,
  view_sessions,
  cart_add_events,
  cart_add_sessions,
  view_to_cart_rate_pct
FROM `PROJECT_ID.futureschole_logs.vw_product_interest_cart_summary`
WHERE view_sessions >= 3
ORDER BY view_sessions DESC, product_label;
