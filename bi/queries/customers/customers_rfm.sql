-- name: customers_rfm
-- description: RFM segmentation of customers at legal-entity level (NIF merges duplicate records; walk-in excluded) over the last `years` years: recency days, invoices, net, margin, R/F/M quintile scores (5 = best) and label (1 Campeoes, 2 Leais, 3 Novos/recentes, 4 Nao pode perder, 5 Em risco, 6 Precisa de atencao, 7 Hibernados). label = all or a label number like 4
-- params: years=3, label=all, limit=200
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
ent AS (SELECT * FROM seg),
asof AS (SELECT MAX(doc_date) AS d FROM sales_facts),
cs AS (SELECT customer_code, SUM(net) AS net FROM sales_facts GROUP BY 1),
names AS (
  SELECT entity_key, segment, codes, name AS main_name FROM (
    SELECT ent.entity_key, ent.segment, ent.name, COUNT(*) OVER (PARTITION BY ent.entity_key) AS codes,
           ROW_NUMBER() OVER (PARTITION BY ent.entity_key ORDER BY COALESCE(cs.net, 0) DESC) AS rn
    FROM ent LEFT JOIN cs USING (customer_code))
  WHERE rn = 1),
base AS (
  SELECT s.entity_key, MAX(f.doc_date) AS last_purchase,
         CAST(julianday((SELECT d FROM asof)) - julianday(MAX(f.doc_date)) AS INTEGER) AS recency_days,
         COUNT(DISTINCT f.doc_id) AS frequency, SUM(f.net) AS monetary, SUM(f.margin) AS margin
  FROM sales_facts f JOIN ent s ON s.customer_code = f.customer_code
  WHERE s.segment <> 'consumidor_final'
    AND f.doc_date >= date((SELECT d FROM asof), '-' || :years || ' years')
  GROUP BY 1 HAVING SUM(f.net) > 0),
sc AS (
  SELECT base.*, 6 - NTILE(5) OVER (ORDER BY recency_days) AS r,
         NTILE(5) OVER (ORDER BY frequency) AS f, NTILE(5) OVER (ORDER BY monetary) AS m
  FROM base),
lab AS (
  SELECT sc.*, CASE
    WHEN r >= 4 AND f >= 4 AND m >= 4 THEN '1 Campeoes'
    WHEN r >= 3 AND f >= 3 AND m >= 3 THEN '2 Leais'
    WHEN r >= 4 AND f <= 2 THEN '3 Novos/recentes'
    WHEN r <= 2 AND f >= 4 AND m >= 4 THEN '4 Nao pode perder'
    WHEN r <= 2 AND (f >= 3 OR m >= 3) THEN '5 Em risco'
    WHEN r = 3 THEN '6 Precisa de atencao'
    ELSE '7 Hibernados' END AS rfm_label
  FROM sc)
SELECT n.main_name AS customer, n.segment, lab.entity_key, n.codes, rfm_label, r, f, m, r || f || m AS rfm,
       last_purchase, recency_days, frequency AS invoices, ROUND(monetary, 2) AS net_sales, ROUND(margin, 2) AS gross_margin
FROM lab JOIN names n USING (entity_key)
WHERE :label = 'all' OR rfm_label LIKE :label || '%'
ORDER BY rfm_label, monetary DESC LIMIT :limit
