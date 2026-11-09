-- name: operations_workload_by_month
-- description: Monthly workload of the shop in gGest: documents created per module (sales invoices/credit notes, repair orders, quotes, purchases, receipts/payments, expenses, other) and in total, active gGest users, working days with documents, and activity-log events. Documents imported at the 2020-03 installation excluded (history from 2020-04). Columns: month, sales, repairs, quotes, purchases, receipts_payments, expenses, other, documents, active_users, working_days, docs_per_day, log_events.
-- params: start=last_year_start, end=today
WITH d AS (
  SELECT month, SUM(module = 'sales') AS sales, SUM(module = 'repairs') AS repairs, SUM(module = 'quotes') AS quotes,
         SUM(module = 'purchases') AS purchases, SUM(module = 'receipts_payments') AS receipts_payments, SUM(module = 'expenses') AS expenses,
         SUM(module NOT IN ('sales','repairs','quotes','purchases','receipts_payments','expenses')) AS other,
         COUNT(*) AS documents, COUNT(DISTINCT user_code) AS active_users, COUNT(DISTINCT date(created_at)) AS working_days
  FROM documents_created WHERE is_migrated = 0 AND date(created_at) BETWEEN :start AND :end GROUP BY month),
l AS (SELECT month, COUNT(*) AS log_events FROM activity_log WHERE event_date BETWEEN :start AND :end GROUP BY month)
SELECT d.*, ROUND(1.0 * d.documents / d.working_days, 1) AS docs_per_day, l.log_events
FROM d LEFT JOIN l ON l.month = d.month
ORDER BY d.month
