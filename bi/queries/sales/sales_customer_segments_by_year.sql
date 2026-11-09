-- name: sales_customer_segments_by_year
-- description: Net sales, margin, documents, customers and average ticket per year by customer segment, using customer_dim.segment (the single segment source of the customers domain: publico, empresa, associativo, particular, consumidor_final; 'sem_ficha' when the document's customer code has no record). Use through_mmdd to compare years to the same day (e.g. through_mmdd=today_mmdd for year-to-date in every year; default 12-31 = full years). Rows: year x segment, plus share of the year's sales.
-- params: start_year=2017, end_year=this_year, through_mmdd=12-31
WITH f AS (
  SELECT f.year, COALESCE(c.segment, 'sem_ficha') AS segment, f.doc_id, f.customer_code, f.net, f.margin
  FROM sales_facts f LEFT JOIN customer_dim c ON c.customer_code = f.customer_code
  WHERE f.year BETWEEN :start_year AND :end_year AND substr(f.doc_date, 6, 5) <= :through_mmdd),
t AS (SELECT year, SUM(net) AS total FROM f GROUP BY year)
SELECT f.year, f.segment,
       ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       ROUND(100.0 * SUM(f.net) / NULLIF(MAX(t.total), 0), 1) AS share_pct,
       COUNT(DISTINCT f.doc_id) AS documents, COUNT(DISTINCT f.customer_code) AS customers,
       ROUND(SUM(f.net) / COUNT(DISTINCT f.doc_id), 2) AS avg_ticket
FROM f JOIN t ON t.year = f.year
GROUP BY f.year, f.segment ORDER BY f.year, net_sales DESC
LIMIT 500
