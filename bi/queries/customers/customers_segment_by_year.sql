-- name: customers_segment_by_year
-- description: Net sales, gross margin, margin %, share of the year, active customers, invoices, net per customer and services net per customer segment (publico / empresa / particular / associativo / consumidor_final) per year. through_mmdd = 12-31 for full years, or today_mmdd to compare every year over the same 01-01..today period (year-to-date)
-- params: start_year=2017, end_year=this_year, through_mmdd=12-31
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim)
SELECT f.year, s.segment, ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       ROUND(100.0 * SUM(f.net) / SUM(SUM(f.net)) OVER (PARTITION BY f.year), 1) AS share_of_year_pct,
       COUNT(DISTINCT f.customer_code) AS customers, COUNT(DISTINCT f.doc_id) AS invoices,
       ROUND(SUM(f.net) / COUNT(DISTINCT f.customer_code), 2) AS net_per_customer,
       ROUND(SUM(CASE WHEN f.line_kind = 'service' THEN f.net ELSE 0 END), 2) AS services_net
FROM sales_facts f JOIN seg s ON s.customer_code = f.customer_code
WHERE f.year BETWEEN :start_year AND :end_year AND substr(f.doc_date, 6, 5) <= :through_mmdd
GROUP BY 1, 2 ORDER BY 1, net_sales DESC
