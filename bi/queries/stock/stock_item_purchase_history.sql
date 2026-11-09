-- name: stock_item_purchase_history
-- description: Purchase history of an item (exact code, or words in the description): every supplier invoice/credit line, newest first. Columns: doc_date, doc_id, supplier_name, item_code, description, qty (negative = returned), unit_price_list, discount_pct, unit_cost_net (after discount, VAT excluded), net. Use to see price evolution and compare suppliers for the same product.
-- params: item=toner hp 415x, limit=50
SELECT doc_date, doc_id, supplier_name, item_code, description, qty, ROUND(unit_price_list,2) AS unit_price_list, discount_pct,
       ROUND(unit_cost_net,2) AS unit_cost_net, ROUND(net,2) AS net
FROM stock_purchase_lines
WHERE is_cancelled = 0 AND item_code IS NOT NULL
  AND (lower(item_code) = lower(trim(:item)) OR lower(description) LIKE '%' || replace(lower(trim(:item)), ' ', '%') || '%')
ORDER BY doc_date DESC, doc_id
LIMIT :limit
