-- name: finance_stock_value_by_group
-- description: Current stock at cost per catalogue group, split into active (sold or bought in the last 12 months), slow (12-24 months without sale or purchase) and dead (more than 24 months). Quantity = Artigos.stock_real (matches totais_stocks running totals for 99.8% of items); unit cost = current average cost (preco_stocks.pmc of the latest year), else last purchase net price. Only goods (tipo A) with positive stock. Quantities are always the CURRENT stock; as_of only moves the activity cut-off.
-- params: as_of=2026-11-08
WITH ls AS (SELECT item_code, MAX(doc_date) AS last_sale FROM sales_facts WHERE qty > 0 GROUP BY item_code),
st AS (
  SELECT a.Codigo AS item_code, COALESCE(g.descricao, '(sem grupo)') AS group_name,
         CAST(a.stock_real AS REAL) AS qty,
         COALESCE(NULLIF(CAST(p.pmc AS REAL),0), CAST(a.ultc_doc_precoliq AS REAL)) AS unit_cost,
         MAX(COALESCE(ls.last_sale,''),
             CASE WHEN a.ultv_doc_data > '19000101' THEN date(substr(a.ultv_doc_data,1,4)||'-'||substr(a.ultv_doc_data,5,2)||'-'||substr(a.ultv_doc_data,7,2)) ELSE '' END,
             CASE WHEN a.ultc_doc_data > '19000101' THEN date(substr(a.ultc_doc_data,1,4)||'-'||substr(a.ultc_doc_data,5,2)||'-'||substr(a.ultc_doc_data,7,2)) ELSE '' END) AS last_move
  FROM Artigos a
  LEFT JOIN Grupos g ON g.Codigo = a.grupo
  LEFT JOIN preco_stocks p ON p.Artigo = a.Codigo AND p.ano = (SELECT MAX(ano) FROM preco_stocks)
  LEFT JOIN ls ON ls.item_code = a.Codigo
  WHERE a.tipo = 'A' AND CAST(a.stock_real AS REAL) > 0)
SELECT group_name, COUNT(*) AS items, ROUND(SUM(qty),0) AS units, ROUND(SUM(qty*unit_cost),0) AS stock_value,
       ROUND(SUM(CASE WHEN last_move >= date(:as_of,'-12 months') THEN qty*unit_cost ELSE 0 END),0) AS active_value,
       ROUND(SUM(CASE WHEN last_move < date(:as_of,'-12 months') AND last_move >= date(:as_of,'-24 months') THEN qty*unit_cost ELSE 0 END),0) AS slow_12_24m_value,
       ROUND(SUM(CASE WHEN last_move < date(:as_of,'-24 months') THEN qty*unit_cost ELSE 0 END),0) AS dead_24m_value,
       ROUND(100.0 * SUM(CASE WHEN last_move < date(:as_of,'-12 months') THEN qty*unit_cost ELSE 0 END) / SUM(qty*unit_cost),1) AS stale_pct
FROM st GROUP BY group_name
UNION ALL
SELECT 'TOTAL', COUNT(*), ROUND(SUM(qty),0), ROUND(SUM(qty*unit_cost),0),
       ROUND(SUM(CASE WHEN last_move >= date(:as_of,'-12 months') THEN qty*unit_cost ELSE 0 END),0),
       ROUND(SUM(CASE WHEN last_move < date(:as_of,'-12 months') AND last_move >= date(:as_of,'-24 months') THEN qty*unit_cost ELSE 0 END),0),
       ROUND(SUM(CASE WHEN last_move < date(:as_of,'-24 months') THEN qty*unit_cost ELSE 0 END),0),
       ROUND(100.0 * SUM(CASE WHEN last_move < date(:as_of,'-12 months') THEN qty*unit_cost ELSE 0 END) / SUM(qty*unit_cost),1)
FROM st
ORDER BY stock_value DESC
