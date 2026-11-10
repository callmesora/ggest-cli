-- name: customers_segment_lookup
-- description: Customer dimension: one row per customer code with derived segment, region and area (view customer_regions), lifetime net sales, first/last purchase and repairs; filter by segment, region or a name fragment
-- params: segment=all, region=all, name=, limit=200
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
f AS (SELECT customer_code, SUM(net) AS net, MIN(doc_date) AS first_purchase, MAX(doc_date) AS last_purchase FROM sales_facts GROUP BY 1),
r AS (SELECT customer_code, COUNT(*) AS repairs, MAX(opened_on) AS last_repair FROM repairs GROUP BY 1)
SELECT seg.customer_code, seg.name, seg.nif, seg.segment, geo.region, geo.area, c.opened_on, c.is_inactive,
       ROUND(COALESCE(f.net, 0), 2) AS net_sales, f.first_purchase, f.last_purchase, COALESCE(r.repairs, 0) AS repairs, r.last_repair
FROM seg JOIN customers c USING (customer_code) LEFT JOIN customer_regions geo USING (customer_code)
LEFT JOIN f USING (customer_code) LEFT JOIN r USING (customer_code)
WHERE (:segment = 'all' OR seg.segment = :segment) AND (:region = 'all' OR geo.region = :region)
  AND (:name = '' OR lower(seg.name) LIKE '%' || lower(:name) || '%')
ORDER BY net_sales DESC LIMIT :limit
