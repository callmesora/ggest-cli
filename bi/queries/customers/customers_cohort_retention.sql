-- name: customers_cohort_retention
-- description: Cohort retention: customers grouped by the year of their first purchase; for each later year, how many bought again (% of the cohort) and what they spent. Walk-in excluded. Current year is partial. segment = all | publico | empresa | particular | associativo
-- params: min_cohort=2017, max_cohort=this_year, segment=all
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
y AS (
  SELECT f.customer_code, f.year, SUM(f.net) AS net
  FROM sales_facts f JOIN seg s ON s.customer_code = f.customer_code
  WHERE s.segment <> 'consumidor_final' AND (:segment = 'all' OR s.segment = :segment)
  GROUP BY 1, 2),
c AS (SELECT customer_code, MIN(year) AS cohort FROM y GROUP BY 1),
size AS (SELECT cohort, COUNT(*) AS cohort_size FROM c GROUP BY 1)
SELECT c.cohort, size.cohort_size, y.year, y.year - c.cohort AS years_after,
       COUNT(*) AS active, ROUND(100.0 * COUNT(*) / size.cohort_size, 1) AS retention_pct,
       ROUND(SUM(y.net), 2) AS net_sales
FROM y JOIN c USING (customer_code) JOIN size USING (cohort)
WHERE c.cohort BETWEEN :min_cohort AND :max_cohort
GROUP BY 1, 2, 3 ORDER BY 1, 3
