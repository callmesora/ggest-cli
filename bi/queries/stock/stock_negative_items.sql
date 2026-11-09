-- name: stock_negative_items
-- description: Items with NEGATIVE stock (sold or used without a recorded entry): data errors to fix with a purchase entry or a stock adjustment. Columns: item_code, description, group, qty_on_hand, unit_cost, value_at_cost, last_sale, last_purchase, last_supplier, last movement (doc and date).
-- params: limit=50
WITH lm AS (
  SELECT item_code, doc_id, doc_date, ROW_NUMBER() OVER (PARTITION BY item_code ORDER BY doc_date DESC, doc_id DESC) AS rn
  FROM stock_movements WHERE item_code IN (SELECT item_code FROM stock_items WHERE qty_on_hand < 0))
SELECT s.item_code, s.description, s.group_name, s.qty_on_hand, ROUND(s.unit_cost,2) AS unit_cost, s.stock_value AS value_at_cost,
       s.last_sale_date AS last_sale, s.last_purchase_date AS last_purchase, s.last_supplier_name AS last_supplier,
       lm.doc_id AS last_movement_doc, lm.doc_date AS last_movement_date
FROM stock_items s LEFT JOIN lm ON lm.item_code = s.item_code AND lm.rn = 1
WHERE s.qty_on_hand < 0
ORDER BY s.stock_value
LIMIT :limit
