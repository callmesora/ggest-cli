-- name: sales_quote_detail
-- description: Lines of one quote / pro-forma / order / loan document (cab_outros) or of all such documents of one customer: doc_id (e.g. 'ORC 2026/120'; leave '' to use customer), customer_code ('' = any). Columns: doc_id, doc_date, outcome (quote_outcomes; NULL for loans/workshop docs), customer, line no, item code/description, qty, converted qty, unit price, line net, unit cost (item's current last purchase price — quotes store no cost; 0 = unknown, e.g. ZZ), line margin %, current catalogue price and stock. Use to rebuild a quote into an invoice or to check what a customer was offered.
-- params: doc_id=, customer_code=, limit=500
SELECT l.doc_id, l.doc_date, o.outcome, q.customer_code, q.customer_name, l.line_no, l.item_code, l.item_description,
       l.line_kind, l.qty, l.converted_qty, ROUND(l.unit_price_net, 2) AS unit_price_net, ROUND(l.net, 2) AS net,
       ROUND(l.unit_cost, 2) AS unit_cost,
       CASE WHEN l.unit_cost > 0 AND l.net > 0 THEN ROUND(100.0 * (l.net - l.qty * l.unit_cost) / l.net, 1) END AS margin_pct,
       i.price_net AS catalogue_price_net, i.stock_qty
FROM quote_lines l
JOIN quote_docs q ON q.doc_id = l.doc_id
LEFT JOIN quote_outcomes o ON o.doc_id = l.doc_id AND (:doc_id <> '' OR :customer_code <> '')
LEFT JOIN items i ON i.item_code = l.item_code
WHERE (:doc_id <> '' AND l.doc_id = :doc_id) OR (:doc_id = '' AND :customer_code <> '' AND l.customer_code = :customer_code)
ORDER BY l.doc_date DESC, l.doc_id, l.line_no
LIMIT :limit
