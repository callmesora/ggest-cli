-- name: sales_item_transactions
-- description: Latest movements of one item (exact item_code; find codes with the product_profile tool): sales lines (sales_facts: invoices and credit notes, with customer, qty, unit price net, unit cost, line margin %), supplier purchase lines (lin_compras: supplier, qty, net unit price after discount; credit notes/returns negative) and quote lines (quote_lines; note = quote kind, "converted" when the line was carried into an invoice — use sales_quote_detail for the outcome). One row per line, newest first; kind = sale / purchase / quote. Answers "a quanto vendemos/comprámos isto da última vez", price history, who buys it. Excludes cancelled documents.
-- params: item_code=ecopchp800g3mini, limit=40
SELECT * FROM (
  SELECT 'sale' AS kind, f.doc_date, f.doc_id, f.customer_code AS entity_code, f.customer_name AS entity_name,
         f.qty, ROUND(f.unit_price_net, 2) AS unit_price_net, ROUND(f.unit_cost, 2) AS unit_cost, ROUND(f.net, 2) AS net,
         CASE WHEN f.net <> 0 THEN ROUND(100.0 * f.margin / f.net, 1) END AS margin_pct, f.cost_source AS note
  FROM sales_facts f WHERE f.item_code = :item_code
  UNION ALL
  SELECT 'purchase', date(substr(l.data_doc,1,4)||'-'||substr(l.data_doc,5,2)||'-'||substr(l.data_doc,7,2)),
         l.Codigo || ' ' || l.serie || '/' || l.numero, l.entidade_codigo, s.name,
         CASE WHEN l.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * CAST(l.quantidade AS REAL),
         CASE WHEN CAST(l.quantidade AS REAL) <> 0 THEN ROUND(CAST(l.Total AS REAL) / CAST(l.quantidade AS REAL), 2) END,
         NULL, CASE WHEN l.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * ROUND(CAST(l.Total AS REAL), 2),
         NULL, l.Codigo
  FROM lin_compras l LEFT JOIN suppliers s ON s.supplier_code = l.entidade_codigo
  WHERE l.Artigo = :item_code AND l.estado_doc <> '1'
  UNION ALL
  SELECT 'quote', l.doc_date, l.doc_id, l.customer_code, q.customer_name, l.qty, ROUND(l.unit_price_net, 2),
         ROUND(l.unit_cost, 2), ROUND(l.net, 2),
         CASE WHEN l.unit_cost > 0 AND l.net > 0 THEN ROUND(100.0 * (l.net - l.qty * l.unit_cost) / l.net, 1) END,
         q.doc_kind || CASE WHEN l.converted_qty > 0 THEN ' converted' ELSE '' END
  FROM quote_lines l JOIN quote_docs q ON q.doc_id = l.doc_id
  WHERE l.item_code = :item_code AND l.is_cancelled = 0
)
ORDER BY doc_date DESC
LIMIT :limit
