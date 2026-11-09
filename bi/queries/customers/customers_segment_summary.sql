-- name: customers_segment_summary
-- description: Customer segments over a whole period (not per year unless by_year = 1): net sales, share, gross margin, margin %, buying customers (records), invoices, net per invoice, net per customer, services share of the segment's sales. Segments from customer_dim: publico / empresa / particular / associativo / consumidor_final. through_mmdd limits every year to 01-01..mm-dd: with start=last_year_start, through_mmdd=today_mmdd, by_year=1 it compares this year-to-date with the same period last year.
-- params: start=2017-01-01, end=today, through_mmdd=12-31, by_year=0
SELECT CASE WHEN :by_year = 1 THEN CAST(f.year AS TEXT) ELSE 'all' END AS period, d.segment,
       ROUND(SUM(f.net), 2) AS net_sales,
       ROUND(100.0 * SUM(f.net) / SUM(SUM(f.net)) OVER (PARTITION BY CASE WHEN :by_year = 1 THEN CAST(f.year AS TEXT) ELSE 'all' END), 1) AS share_pct,
       ROUND(SUM(f.margin), 2) AS gross_margin, ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       COUNT(DISTINCT f.customer_code) AS customers, COUNT(DISTINCT f.doc_id) AS invoices,
       ROUND(SUM(f.net) / COUNT(DISTINCT f.doc_id), 2) AS net_per_invoice,
       ROUND(SUM(f.net) / COUNT(DISTINCT f.customer_code), 2) AS net_per_customer,
       ROUND(100.0 * SUM(CASE WHEN f.line_kind = 'service' THEN f.net ELSE 0 END) / NULLIF(SUM(f.net), 0), 1) AS services_pct
FROM sales_facts f JOIN customer_dim d ON d.customer_code = f.customer_code
WHERE f.doc_date BETWEEN :start AND :end AND substr(f.doc_date, 6, 5) <= :through_mmdd
GROUP BY 1, 2 ORDER BY 1, net_sales DESC
