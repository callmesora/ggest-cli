-- name: stock_item_lookup
-- description: Stock check for one item (or items matching a search): `search` = exact item code, barcode, or words in the description (all words must match, e.g. "toner 415x"). Columns: item_code, description, group, qty_on_hand, qty_available (on hand minus reserved/delivery notes), qty_reserved, unit_cost (average cost pmc), stock_value, price_net, margin_pct (at unit_cost), units sold (net of returns) in the last 90 and 365 days, last_sale, last_purchase (date of the last real purchase invoice), last_purchase_doc, last_supplier, last_cost (net unit cost on that invoice; quotes, returns and stock adjustments are ignored), cost_warning ('pmc_vs_last_cost' when average cost and last cost differ by more than 20 %: the average cost may be stale, check margin with both), has_serials (1 = serial-numbered item: use stock_serial_lookup / stock_serials_sold). Single warehouse in this database. Exact code matches first, then by stock.
-- params: search=toner, as_of=today, limit=20
WITH q AS (SELECT lower(trim(:search)) AS s),
cand AS (
  SELECT s.* FROM stock_items s, q
  WHERE s.kind IN ('product','') AND (lower(s.item_code) = q.s OR s.barcode = trim(:search)
     OR lower(s.description) LIKE '%' || replace(q.s, ' ', '%') || '%'
     OR lower(s.item_code) LIKE '%' || q.s || '%')),
sold AS (
  SELECT m.item_code,
         -SUM(CASE WHEN m.doc_date > date(:as_of,'-90 days') THEN m.qty ELSE 0 END) AS sold_90d,
         -SUM(CASE WHEN m.doc_date > date(:as_of,'-365 days') THEN m.qty ELSE 0 END) AS sold_365d
  FROM stock_movements m JOIN cand c ON c.item_code = m.item_code
  WHERE m.movement_kind IN ('sale','sale_return') GROUP BY m.item_code)
SELECT c.item_code, c.description, c.group_name, c.qty_on_hand, c.qty_available, c.qty_reserved,
       ROUND(c.unit_cost,2) AS unit_cost, c.stock_value, ROUND(c.price_net,2) AS price_net,
       CASE WHEN c.price_net > 0 THEN ROUND(100.0*(c.price_net - c.unit_cost)/c.price_net,1) END AS margin_pct,
       CAST(COALESCE(sold.sold_90d,0) AS REAL) AS sold_90d, CAST(COALESCE(sold.sold_365d,0) AS REAL) AS sold_365d,
       c.last_sale_date AS last_sale, c.last_purchase_date AS last_purchase, c.last_purchase_doc, c.last_supplier_name AS last_supplier,
       ROUND(c.last_purchase_cost,2) AS last_cost, c.cost_warning,
       CASE WHEN EXISTS (SELECT 1 FROM lin_mov_series x WHERE x.Artigo = c.item_code) THEN 1 ELSE 0 END AS has_serials
FROM cand c LEFT JOIN sold ON sold.item_code = c.item_code
ORDER BY CASE WHEN lower(c.item_code) = lower(trim(:search)) THEN 0 ELSE 1 END, c.qty_on_hand DESC, c.last_sale_date DESC
LIMIT :limit
