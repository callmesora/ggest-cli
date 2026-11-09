-- name: operations_cancellations_by_year
-- description: Process-quality control (aggregate): per year and gGest area, how many records were cancelled (ANULOU), deleted (ELIMINOU) or saved overriding a lock (IGNOROUBLOQUEIO) according to the activity log, and the number of users involved. High counts in an area point to rework or training needs (e.g. invoices issued with errors). Cancelled sales documents with their reasons: sales_credit_cancel_reasons. Columns: year, area, cancelled, deleted, lock_overrides, users.
-- params: from_year=years_ago_3, limit=60
SELECT year, area, SUM(operation = 'ANULOU') AS cancelled, SUM(operation = 'ELIMINOU') AS deleted,
       SUM(operation = 'IGNOROUBLOQUEIO') AS lock_overrides, COUNT(DISTINCT user_code) AS users
FROM activity_log
WHERE operation IN ('ANULOU','ELIMINOU','IGNOROUBLOQUEIO') AND year >= CAST(:from_year AS INTEGER)
GROUP BY year, area
ORDER BY year DESC, COUNT(*) DESC
LIMIT :limit
