-- name: management_monthly_scorecard
-- description: One row per month of a year with the same month of the previous year: net sales, gross margin, margin %, invoices, distinct customers, repairs opened, and the change in net sales vs last year (%). Months after the last date in the data are left out. Use it for a monthly business review or to spot which month made the year better or worse.
-- params: year=this_year
WITH s AS (
  SELECT year, CAST(substr(month, 6, 2) AS INTEGER) AS m, SUM(net) AS net, SUM(margin) AS margin,
         COUNT(DISTINCT doc_id) AS docs, COUNT(DISTINCT customer_code) AS customers
  FROM sales_facts WHERE year IN (:year, :year - 1) GROUP BY 1, 2),
r AS (
  SELECT CAST(substr(opened_on, 1, 4) AS INTEGER) AS year, CAST(substr(opened_on, 6, 2) AS INTEGER) AS m, COUNT(*) AS repairs
  FROM repairs WHERE substr(opened_on, 1, 4) IN (CAST(:year AS TEXT), CAST(:year - 1 AS TEXT)) GROUP BY 1, 2)
SELECT printf('%d-%02d', :year, c.m) AS month,
       ROUND(c.net, 0) AS net, ROUND(p.net, 0) AS net_last_year,
       ROUND(100.0 * (c.net - p.net) / NULLIF(p.net, 0), 1) AS net_change_pct,
       ROUND(c.margin, 0) AS margin, ROUND(p.margin, 0) AS margin_last_year,
       ROUND(100.0 * c.margin / NULLIF(c.net, 0), 1) AS margin_pct,
       c.docs AS invoices, p.docs AS invoices_last_year, c.customers,
       rc.repairs, rp.repairs AS repairs_last_year
FROM s c
LEFT JOIN s p ON p.year = :year - 1 AND p.m = c.m
LEFT JOIN r rc ON rc.year = :year AND rc.m = c.m
LEFT JOIN r rp ON rp.year = :year - 1 AND rp.m = c.m
WHERE c.year = :year
ORDER BY c.m
