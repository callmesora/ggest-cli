-- name: customers_history_by_year
-- description: One customer's relationship year by year. customer = customer code or NIF (a NIF takes every record with that NIF; merge_nif = 1 also merges the records sharing the code's NIF). Per year: net sales, gross margin, margin %, invoices, credit notes, goods vs services net, quotes issued, repair orders opened and the product group it bought most. Years with only repairs or quotes are listed too. Use customers_briefing first to find the code.
-- params: customer=, merge_nif=1
WITH t AS MATERIALIZED (
  SELECT d.customer_code FROM customer_dim d
  WHERE d.customer_code = :customer OR d.nif_clean = upper(replace(:customer, ' ', ''))
     OR (:merge_nif = 1 AND d.entity_key = (SELECT entity_key FROM customer_dim WHERE customer_code = :customer))),
s AS (
  SELECT year, SUM(net) AS net, SUM(margin) AS margin,
         COUNT(DISTINCT CASE WHEN doc_class = 'invoice' THEN doc_id END) AS invoices,
         COUNT(DISTINCT CASE WHEN doc_class = 'credit_note' THEN doc_id END) AS credit_notes,
         SUM(CASE WHEN line_kind = 'service' THEN net ELSE 0 END) AS services_net
  FROM sales_facts WHERE customer_code IN (SELECT customer_code FROM t) GROUP BY 1),
g AS (
  SELECT year, group_name, ROW_NUMBER() OVER (PARTITION BY year ORDER BY SUM(net) DESC) AS rn
  FROM sales_facts WHERE customer_code IN (SELECT customer_code FROM t) AND line_kind = 'product' GROUP BY 1, 2),
q AS (
  SELECT CAST(substr(data_doc,1,4) AS INTEGER) AS year, COUNT(*) AS quotes FROM cab_outros
  WHERE Codigo = 'ORC' AND estado_doc <> '1' AND entidade_codigo IN (SELECT customer_code FROM t) GROUP BY 1),
r AS (SELECT year, COUNT(*) AS repairs FROM repairs WHERE customer_code IN (SELECT customer_code FROM t) GROUP BY 1),
y AS (SELECT year FROM s UNION SELECT year FROM q UNION SELECT year FROM r)
SELECT y.year, ROUND(COALESCE(s.net,0),2) AS net_sales, ROUND(COALESCE(s.margin,0),2) AS gross_margin,
       ROUND(100.0 * s.margin / NULLIF(s.net,0),1) AS margin_pct, COALESCE(s.invoices,0) AS invoices,
       COALESCE(s.credit_notes,0) AS credit_notes, ROUND(COALESCE(s.net,0) - COALESCE(s.services_net,0),2) AS goods_and_fees_net,
       ROUND(COALESCE(s.services_net,0),2) AS services_net, COALESCE(q.quotes,0) AS quotes, COALESCE(r.repairs,0) AS repairs,
       g.group_name AS top_product_group
FROM y LEFT JOIN s USING (year) LEFT JOIN q USING (year) LEFT JOIN r USING (year)
LEFT JOIN g ON g.year = y.year AND g.rn = 1
ORDER BY y.year
