-- name: customers_top_entities
-- description: Top customers grouped by legal entity (NIF), so duplicate records and departments sharing a NIF are merged: net sales, gross margin, share, segment, codes merged, first/last purchase, repairs_in_period_entity (repair orders opened between start and end on ALL records of the entity, so it differs from per-record or all-time counts such as top_customers.repairs_all_time), largest_invoice_net and largest_invoice_share_pct (share of the entity's period sales made by its single largest invoice: high = one-off project, not a regular customer). by = net | margin | invoices; segment = all | publico | empresa | particular | associativo
-- params: start=2017-01-01, end=today, by=net, segment=all, limit=30
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
ent AS (SELECT * FROM seg),
s AS (
  SELECT e.entity_key, SUM(f.net) AS net_sales, SUM(f.margin) AS gross_margin, COUNT(DISTINCT f.doc_id) AS invoices,
         MIN(f.doc_date) AS first_purchase, MAX(f.doc_date) AS last_purchase, COUNT(DISTINCT f.year) AS active_years
  FROM sales_facts f JOIN ent e ON e.customer_code = f.customer_code
  WHERE f.doc_date BETWEEN :start AND :end AND e.segment <> 'consumidor_final'
  GROUP BY 1),
cs AS (SELECT customer_code, SUM(net) AS net FROM sales_facts WHERE doc_date BETWEEN :start AND :end GROUP BY 1),
names AS (
  SELECT entity_key, segment, codes, customer_codes, name AS main_name FROM (
    SELECT ent.entity_key, ent.segment, ent.name,
           COUNT(*) OVER (PARTITION BY ent.entity_key) AS codes,
           group_concat(ent.customer_code, ',') OVER (PARTITION BY ent.entity_key) AS customer_codes,
           ROW_NUMBER() OVER (PARTITION BY ent.entity_key ORDER BY COALESCE(cs.net, 0) DESC) AS rn
    FROM ent LEFT JOIN cs USING (customer_code)
    WHERE ent.entity_key IN (SELECT entity_key FROM s))
  WHERE rn = 1),
r AS (SELECT e.entity_key, COUNT(*) AS repairs FROM repairs rp JOIN ent e ON e.customer_code = rp.customer_code
      WHERE rp.opened_on BETWEEN :start AND :end GROUP BY 1),
li AS (SELECT e.entity_key, MAX(f.net) AS largest_invoice_net FROM
        (SELECT doc_id, customer_code, SUM(net) AS net FROM sales_facts WHERE doc_date BETWEEN :start AND :end GROUP BY 1, 2) f
        JOIN ent e ON e.customer_code = f.customer_code GROUP BY 1)
SELECT n.main_name AS customer, n.segment, s.entity_key, n.codes, n.customer_codes,
       ROUND(s.net_sales, 2) AS net_sales, ROUND(s.gross_margin, 2) AS gross_margin,
       ROUND(100.0 * s.gross_margin / NULLIF(s.net_sales, 0), 1) AS margin_pct,
       ROUND(100.0 * s.net_sales / (SELECT SUM(net) FROM sales_facts WHERE doc_date BETWEEN :start AND :end), 2) AS share_pct,
       s.invoices, s.active_years, s.first_purchase, s.last_purchase, COALESCE(r.repairs, 0) AS repairs_in_period_entity,
       ROUND(li.largest_invoice_net, 2) AS largest_invoice_net, ROUND(100.0 * li.largest_invoice_net / NULLIF(s.net_sales, 0), 1) AS largest_invoice_share_pct
FROM s JOIN names n USING (entity_key) LEFT JOIN r USING (entity_key) LEFT JOIN li USING (entity_key)
WHERE :segment = 'all' OR n.segment = :segment
ORDER BY CASE :by WHEN 'margin' THEN s.gross_margin WHEN 'invoices' THEN s.invoices ELSE s.net_sales END DESC
LIMIT :limit
