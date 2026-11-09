-- name: customers_concentration_by_year
-- description: Customer concentration per year (walk-in excluded, legal entity = NIF): active customers, net sales, average per customer, share of top 1/10/20/50 and how many customers make 50% and 80% of sales
-- params: start_year=2017, end_year=this_year
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
ent AS (SELECT * FROM seg),
y AS (
  SELECT f.year, e.entity_key, SUM(f.net) AS net
  FROM sales_facts f JOIN ent e ON e.customer_code = f.customer_code
  WHERE f.year BETWEEN :start_year AND :end_year AND e.segment <> 'consumidor_final'
  GROUP BY 1, 2 HAVING SUM(f.net) > 0),
rk AS (
  SELECT year, entity_key, net,
         ROW_NUMBER() OVER (PARTITION BY year ORDER BY net DESC) AS rn,
         SUM(net) OVER (PARTITION BY year ORDER BY net DESC ROWS UNBOUNDED PRECEDING) AS cum,
         SUM(net) OVER (PARTITION BY year) AS tot
  FROM y)
SELECT year, COUNT(*) AS customers, ROUND(MAX(tot), 2) AS net_sales,
       ROUND(MAX(tot) / COUNT(*), 2) AS avg_per_customer,
       ROUND(100.0 * SUM(CASE WHEN rn = 1 THEN net END) / MAX(tot), 1) AS top1_pct,
       ROUND(100.0 * SUM(CASE WHEN rn <= 10 THEN net END) / MAX(tot), 1) AS top10_pct,
       ROUND(100.0 * SUM(CASE WHEN rn <= 20 THEN net END) / MAX(tot), 1) AS top20_pct,
       ROUND(100.0 * SUM(CASE WHEN rn <= 50 THEN net END) / MAX(tot), 1) AS top50_pct,
       MIN(CASE WHEN cum >= 0.5 * tot THEN rn END) AS customers_for_50pct,
       MIN(CASE WHEN cum >= 0.8 * tot THEN rn END) AS customers_for_80pct
FROM rk GROUP BY year ORDER BY year
