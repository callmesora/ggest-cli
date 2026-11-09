-- name: finance_dead_stock_items
-- description: Items in stock with no sale AND no purchase for at least `months` months (dead / slow stock), valued at cost, most valuable first. Candidates for promotion, bundling, return to supplier or write-off. Same quantity/cost rules as finance_stock_value_by_group. last_sale blank = never sold since 2017.
-- params: as_of=2026-11-08, months=12, min_value=0, limit=50
WITH ls AS (SELECT item_code, MAX(doc_date) AS last_sale FROM sales_facts WHERE qty > 0 GROUP BY item_code),
st AS (
  SELECT a.Codigo AS item_code, trim(a.descricao) AS description, COALESCE(g.descricao, '(sem grupo)') AS group_name,
         CAST(a.stock_real AS REAL) AS qty,
         COALESCE(NULLIF(CAST(p.pmc AS REAL),0), CAST(a.ultc_doc_precoliq AS REAL)) AS unit_cost,
         CAST(a.pvp1 AS REAL) AS price_net,
         COALESCE(ls.last_sale, CASE WHEN a.ultv_doc_data > '19000101' THEN date(substr(a.ultv_doc_data,1,4)||'-'||substr(a.ultv_doc_data,5,2)||'-'||substr(a.ultv_doc_data,7,2)) END) AS last_sale,
         CASE WHEN a.ultc_doc_data > '19000101' THEN date(substr(a.ultc_doc_data,1,4)||'-'||substr(a.ultc_doc_data,5,2)||'-'||substr(a.ultc_doc_data,7,2)) END AS last_purchase,
         trim(a.ultc_doc_entdescr) AS last_supplier
  FROM Artigos a
  LEFT JOIN Grupos g ON g.Codigo = a.grupo
  LEFT JOIN preco_stocks p ON p.Artigo = a.Codigo AND p.ano = (SELECT MAX(ano) FROM preco_stocks)
  LEFT JOIN ls ON ls.item_code = a.Codigo
  WHERE a.tipo = 'A' AND CAST(a.stock_real AS REAL) > 0)
SELECT item_code, description, group_name, qty, ROUND(unit_cost,2) AS unit_cost, ROUND(qty*unit_cost,2) AS stock_value,
       ROUND(price_net,2) AS price_net, last_sale, last_purchase, last_supplier,
       CAST(julianday(:as_of) - julianday(MAX(COALESCE(last_sale,'2000-01-01'), COALESCE(last_purchase,'2000-01-01'))) AS INTEGER) AS days_without_movement
FROM st
WHERE MAX(COALESCE(last_sale,''), COALESCE(last_purchase,'')) < date(:as_of, '-' || :months || ' months')
  AND qty*unit_cost >= :min_value
ORDER BY qty*unit_cost DESC LIMIT :limit
