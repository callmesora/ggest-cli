-- name: customers_duplicates
-- description: Possible duplicate customer records: customer codes sharing the same NIF (kind = nif) or the same normalised name (kind = name). same_name = 1 is usually a real duplicate to merge; 0 with a public NIF usually means departments of one body. Shows sales and repairs per group
-- params: kind=nif, min_codes=2, limit=100
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
k AS (
  SELECT seg.*, CASE WHEN :kind = 'name' THEN lower(trim(replace(replace(replace(name, '.', ''), ',', ''), '  ', ' ')))
                     ELSE CASE WHEN length(nf) = 9 AND nf GLOB '[0-9]*' AND nf <> '999999990' THEN nf END END AS dkey
  FROM seg WHERE segment <> 'consumidor_final'),
s AS (SELECT customer_code, SUM(net) AS net, MAX(doc_date) AS last_purchase FROM sales_facts GROUP BY 1),
r AS (SELECT customer_code, COUNT(*) AS repairs FROM repairs GROUP BY 1)
SELECT k.dkey AS duplicate_key, COUNT(*) AS codes, group_concat(k.customer_code || '=' || k.name, ' | ') AS records,
       COUNT(DISTINCT lower(trim(k.name))) = 1 AS same_name, MAX(k.segment) AS segment,
       COUNT(DISTINCT k.nf) AS distinct_nifs, SUM(s.customer_code IS NOT NULL) AS codes_with_sales,
       ROUND(SUM(s.net), 2) AS net_sales, MAX(s.last_purchase) AS last_purchase, COALESCE(SUM(r.repairs), 0) AS repairs
FROM k LEFT JOIN s USING (customer_code) LEFT JOIN r USING (customer_code)
WHERE k.dkey IS NOT NULL AND k.dkey <> ''
GROUP BY k.dkey HAVING COUNT(*) >= :min_codes
ORDER BY codes_with_sales DESC, net_sales DESC LIMIT :limit
