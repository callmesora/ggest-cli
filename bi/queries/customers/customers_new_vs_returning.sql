-- name: customers_new_vs_returning
-- description: Per year: active buying customers split into new (first purchase that year; sales history starts 2017 so 2017 is all 'new'), returning, and new buyers already known from repairs (assistencia before their first purchase); revenue of each group. through_mmdd = 12-31 for full years or today_mmdd for year-to-date (new = first ever purchase falls in that year and window)
-- params: start_year=2017, end_year=this_year, through_mmdd=12-31
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
first_sale AS (SELECT customer_code, MIN(year) AS first_year, MIN(doc_date) AS first_date FROM sales_facts GROUP BY 1),
first_rep AS (SELECT customer_code, MIN(opened_on) AS first_repair FROM repairs GROUP BY 1),
y AS (
  SELECT f.year, f.customer_code, SUM(f.net) AS net
  FROM sales_facts f JOIN seg s ON s.customer_code = f.customer_code
  WHERE s.segment <> 'consumidor_final' AND substr(f.doc_date, 6, 5) <= :through_mmdd GROUP BY 1, 2)
SELECT y.year, COUNT(*) AS active_customers,
       SUM(y.year = fs.first_year) AS new_customers,
       SUM(y.year > fs.first_year) AS returning_customers,
       SUM(y.year = fs.first_year AND fr.first_repair < fs.first_date) AS new_buyers_known_from_repairs,
       ROUND(100.0 * SUM(y.year = fs.first_year) / COUNT(*), 1) AS new_pct,
       ROUND(SUM(CASE WHEN y.year = fs.first_year THEN y.net ELSE 0 END), 2) AS net_from_new,
       ROUND(SUM(CASE WHEN y.year > fs.first_year THEN y.net ELSE 0 END), 2) AS net_from_returning,
       ROUND(100.0 * SUM(CASE WHEN y.year > fs.first_year THEN y.net ELSE 0 END) / SUM(y.net), 1) AS returning_net_pct
FROM y JOIN first_sale fs USING (customer_code) LEFT JOIN first_rep fr USING (customer_code)
WHERE y.year BETWEEN :start_year AND :end_year
GROUP BY 1 ORDER BY 1
