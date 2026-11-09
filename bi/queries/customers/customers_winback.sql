-- name: customers_winback
-- description: Win-back list at legal-entity level (NIF; records/departments sharing a NIF are merged so renamed public bodies are not false churn): entities with lifetime net >= min_net and no purchase in the last inactive_days days (as of the last sale date), with segment, records_same_nif (customer records merged into this NIF entity; each NIF is its own row, so a body with two NIFs appears twice) and their codes, best year, last purchase, last repair (repaired_after_last_purchase = 1 means still in touch) and net per active year. repairs_all_time_entity = all repair orders ever on the entity's records. same_name_active_code = an ACTIVE record of another entity with the same name once company words (lda, unipessoal, limitada, sociedade) are removed (person now buying through own company, or a public body under a new NIF). For offers per customer use customers_winback_products
-- params: min_net=1000, inactive_days=540, segment=all, limit=50
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
ent AS (SELECT * FROM seg),
asof AS (SELECT MAX(doc_date) AS d FROM sales_facts),
cs AS (SELECT customer_code, SUM(net) AS net FROM sales_facts GROUP BY 1),
names AS (
  SELECT entity_key, segment, codes, customer_codes, name AS main_name FROM (
    SELECT ent.entity_key, ent.segment, ent.name, COUNT(*) OVER (PARTITION BY ent.entity_key) AS codes,
           group_concat(ent.customer_code, ',') OVER (PARTITION BY ent.entity_key) AS customer_codes,
           ROW_NUMBER() OVER (PARTITION BY ent.entity_key ORDER BY COALESCE(cs.net, 0) DESC) AS rn
    FROM ent LEFT JOIN cs USING (customer_code))
  WHERE rn = 1),
s AS (
  SELECT e.entity_key, SUM(f.net) AS net_sales, SUM(f.margin) AS gross_margin, COUNT(DISTINCT f.doc_id) AS invoices,
         COUNT(DISTINCT f.year) AS active_years, MIN(f.doc_date) AS first_purchase, MAX(f.doc_date) AS last_purchase
  FROM sales_facts f JOIN ent e ON e.customer_code = f.customer_code
  WHERE e.segment <> 'consumidor_final' GROUP BY 1),
best AS (
  SELECT entity_key, year AS best_year, net AS best_year_net FROM (
    SELECT e.entity_key, f.year, SUM(f.net) AS net,
           ROW_NUMBER() OVER (PARTITION BY e.entity_key ORDER BY SUM(f.net) DESC) AS rn
    FROM sales_facts f JOIN ent e ON e.customer_code = f.customer_code GROUP BY 1, 2) WHERE rn = 1),
r AS (SELECT e.entity_key, SUM(a.repairs) AS repairs, MAX(a.last_repair) AS last_repair
      FROM customer_activity a JOIN ent e ON e.customer_code = a.customer_code GROUP BY 1),
core AS (
  SELECT seg.customer_code, seg.entity_key,
         trim(replace(replace(replace(replace(replace(seg.n, ' unipessoal ', ' '), ' lda ', ' '), ' limitada ', ' '),
              ' sociedade ', ' '), '  ', ' ')) AS k
  FROM seg WHERE seg.segment <> 'consumidor_final'),
act AS MATERIALIZED (
  SELECT core.k, core.entity_key, MIN(core.customer_code) AS code FROM core JOIN customer_activity a USING (customer_code)
  WHERE a.last_purchase > date((SELECT d FROM asof), '-' || :inactive_days || ' days') AND length(core.k) >= 8 GROUP BY 1, 2),
nl AS (
  SELECT core.entity_key, MIN(act.code) AS same_name_active_code
  FROM core JOIN act ON act.k = core.k AND act.entity_key <> core.entity_key GROUP BY 1)
SELECT n.main_name AS customer, n.segment, s.entity_key, n.codes AS records_same_nif, n.customer_codes,
       ROUND(s.net_sales, 2) AS net_sales, ROUND(s.gross_margin, 2) AS gross_margin, s.invoices, s.active_years,
       ROUND(s.net_sales / s.active_years, 2) AS net_per_active_year, best.best_year, ROUND(best.best_year_net, 2) AS best_year_net,
       s.first_purchase, s.last_purchase,
       CAST(julianday((SELECT d FROM asof)) - julianday(s.last_purchase) AS INTEGER) AS days_since_purchase,
       COALESCE(r.repairs, 0) AS repairs_all_time_entity, r.last_repair,
       CASE WHEN r.last_repair > s.last_purchase THEN 1 ELSE 0 END AS repaired_after_last_purchase,
       nl.same_name_active_code
FROM s JOIN names n USING (entity_key) LEFT JOIN best USING (entity_key) LEFT JOIN r USING (entity_key) LEFT JOIN nl USING (entity_key)
WHERE s.net_sales >= :min_net
  AND julianday((SELECT d FROM asof)) - julianday(s.last_purchase) >= :inactive_days
  AND (:segment = 'all' OR n.segment = :segment)
ORDER BY s.net_sales DESC LIMIT :limit
