-- name: customers_purchase_mix
-- description: What one customer buys: net sales, gross margin, quantity, invoices and last purchase by product group and family in the period, with the best-selling item of each family and its share of the customer's spend. customer = customer code or NIF; merge_nif = 1 includes the other records with the same NIF. Use for cross-sell ideas (what they buy elsewhere is missing) and to see consumables patterns (toner/ink re-orders).
-- params: customer=, merge_nif=1, start=2017-01-01, end=today, limit=40
WITH t AS MATERIALIZED (
  SELECT d.customer_code FROM customer_dim d
  WHERE d.customer_code = :customer OR d.nif_clean = upper(replace(:customer, ' ', ''))
     OR (:merge_nif = 1 AND d.entity_key = (SELECT entity_key FROM customer_dim WHERE customer_code = :customer))),
f AS (SELECT * FROM sales_facts WHERE customer_code IN (SELECT customer_code FROM t) AND doc_date BETWEEN :start AND :end),
top AS (
  SELECT group_name, family_name, item_description,
         ROW_NUMBER() OVER (PARTITION BY group_name, family_name ORDER BY SUM(net) DESC) AS rn
  FROM f GROUP BY 1, 2, 3)
SELECT f.group_name, f.family_name, f.line_kind, ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       ROUND(100.0 * SUM(f.net) / (SELECT SUM(net) FROM f), 1) AS share_pct,
       ROUND(SUM(f.qty), 1) AS qty, COUNT(DISTINCT f.doc_id) AS invoices, MIN(f.doc_date) AS first_purchase,
       MAX(f.doc_date) AS last_purchase, MAX(top.item_description) AS top_item
FROM f LEFT JOIN top ON top.group_name IS f.group_name AND top.family_name IS f.family_name AND top.rn = 1
GROUP BY 1, 2, 3 ORDER BY net_sales DESC LIMIT :limit
