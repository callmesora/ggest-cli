-- name: stock_item_movements
-- description: Stock card (kardex) of one item: every document that moved its stock since `start`, newest first, with the running balance after each movement (computed back from the current stock). Columns: doc_date, doc_id, movement_kind (sale, sale_return, purchase, purchase_return, assembly_in/out, adjustment_in/out, write_off, internal_use, warranty_use, workshop_use, loan_out, sponsorship), entity (customer or supplier name), qty (+ in / - out), unit_cost, unit_price (net, for sales/purchases), balance_after. `item` = exact item code (use stock_item_lookup to find it).
-- params: item=W2030X, start=years_ago_3, limit=100
WITH m AS (
  SELECT m.*, s.qty_on_hand,
         SUM(m.qty) OVER (ORDER BY m.doc_date DESC, m.doc_id DESC, m.qty ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS later_qty
  FROM stock_movements m JOIN stock_items s ON s.item_code = m.item_code
  WHERE m.item_code = :item)
SELECT m.doc_date, m.doc_id, m.movement_kind,
       CASE m.entity_kind WHEN 'customer' THEN c.name WHEN 'supplier' THEN sp.name END AS entity,
       m.qty, ROUND(m.unit_cost,2) AS unit_cost, ROUND(m.unit_price,2) AS unit_price,
       m.qty_on_hand - COALESCE(m.later_qty,0) AS balance_after
FROM m
LEFT JOIN customers c ON m.entity_kind = 'customer' AND c.customer_code = m.entity_code
LEFT JOIN suppliers sp ON m.entity_kind = 'supplier' AND sp.supplier_code = m.entity_code
WHERE m.doc_date >= CASE WHEN length(:start) = 4 THEN :start || '-01-01' ELSE :start END
ORDER BY m.doc_date DESC, m.doc_id DESC, m.qty
LIMIT :limit
