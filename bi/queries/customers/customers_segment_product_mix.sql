-- name: customers_segment_product_mix
-- description: What each customer segment buys: net sales, margin and share by product group and line kind. segment = all | publico | empresa | particular | associativo
-- params: start=2017-01-01, end=today, segment=all, limit=60
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim)
SELECT s.segment, COALESCE(f.group_name, '(' || f.line_kind || ')') AS group_name, f.line_kind,
       ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       ROUND(100.0 * SUM(f.net) / SUM(SUM(f.net)) OVER (PARTITION BY s.segment), 1) AS share_of_segment_pct,
       COUNT(DISTINCT f.customer_code) AS customers
FROM sales_facts f JOIN seg s ON s.customer_code = f.customer_code
WHERE f.doc_date BETWEEN :start AND :end AND (:segment = 'all' OR s.segment = :segment)
GROUP BY 1, 2, 3 ORDER BY 1, net_sales DESC LIMIT :limit
