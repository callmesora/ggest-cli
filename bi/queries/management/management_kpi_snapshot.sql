-- name: management_kpi_snapshot
-- description: The business at a glance, year-to-date at the data date vs the same period last year (one row per KPI, with value, last-year value and change %): net sales, gross margin, margin %, invoices, average invoice, active customers, new customers (first purchase ever in the period), repairs opened, repair labour/services sold, open repair orders now, and the data date itself. Start every "how is the business doing" question here.
-- params: as_of=today, as_of_last_year=today_last_year, start=year_start, start_last_year=last_year_start
WITH p AS (
  SELECT 'cur' AS per, :start AS a, :as_of AS b UNION ALL SELECT 'prev', :start_last_year, :as_of_last_year),
first_buy AS (SELECT customer_code, MIN(doc_date) AS first_date FROM sales_facts GROUP BY 1),
s AS (
  SELECT p.per, SUM(f.net) AS net, SUM(f.margin) AS margin, COUNT(DISTINCT f.doc_id) AS docs,
         COUNT(DISTINCT f.customer_code) AS customers
  FROM p JOIN sales_facts f ON f.doc_date BETWEEN p.a AND p.b GROUP BY p.per),
n AS (
  SELECT p.per, COUNT(*) AS new_customers FROM p JOIN first_buy b ON b.first_date BETWEEN p.a AND p.b GROUP BY p.per),
r AS (SELECT p.per, COUNT(*) AS repairs FROM p JOIN repairs x ON x.opened_on BETWEEN p.a AND p.b GROUP BY p.per),
l AS (
  SELECT p.per, SUM(f.net) AS services FROM p JOIN sales_facts f ON f.doc_date BETWEEN p.a AND p.b
  WHERE f.line_kind = 'service' GROUP BY p.per),
k AS (
  SELECT 1 AS o, 'net_sales' AS kpi, (SELECT net FROM s WHERE per='cur') AS v, (SELECT net FROM s WHERE per='prev') AS lv
  UNION ALL SELECT 2, 'gross_margin', (SELECT margin FROM s WHERE per='cur'), (SELECT margin FROM s WHERE per='prev')
  UNION ALL SELECT 3, 'margin_pct', (SELECT 100.0*margin/net FROM s WHERE per='cur'), (SELECT 100.0*margin/net FROM s WHERE per='prev')
  UNION ALL SELECT 4, 'invoices', (SELECT docs FROM s WHERE per='cur'), (SELECT docs FROM s WHERE per='prev')
  UNION ALL SELECT 5, 'avg_invoice', (SELECT net/docs FROM s WHERE per='cur'), (SELECT net/docs FROM s WHERE per='prev')
  UNION ALL SELECT 6, 'active_customers', (SELECT customers FROM s WHERE per='cur'), (SELECT customers FROM s WHERE per='prev')
  UNION ALL SELECT 7, 'new_customers', (SELECT new_customers FROM n WHERE per='cur'), (SELECT new_customers FROM n WHERE per='prev')
  UNION ALL SELECT 8, 'repairs_opened', (SELECT repairs FROM r WHERE per='cur'), (SELECT repairs FROM r WHERE per='prev')
  UNION ALL SELECT 9, 'services_sold', (SELECT services FROM l WHERE per='cur'), (SELECT services FROM l WHERE per='prev')
  UNION ALL SELECT 10, 'open_repair_orders_now', (SELECT COUNT(*) FROM repairs WHERE status_code IN ('ABR','INT','PRO')), NULL)
SELECT kpi, ROUND(v, 1) AS value, ROUND(lv, 1) AS last_year, ROUND(100.0 * (v - lv) / NULLIF(lv, 0), 1) AS change_pct,
       :start || ' .. ' || :as_of AS period
FROM k ORDER BY o
