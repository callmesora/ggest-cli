-- name: stock_supplier_items
-- description: What we buy from one supplier (`supplier` = code or part of the name) in a period: top items by spend with units, average and latest net unit cost, last purchase date, units sold in the same period (stock_movements) and current stock. Columns: supplier_name, item_code, description, group, qty_bought, spend, avg_cost, last_cost, last_bought, qty_sold, qty_on_hand.
-- params: supplier=23, start=last_year_start, end=today, limit=30
WITH l AS (
  SELECT * FROM stock_purchase_lines
  WHERE is_cancelled = 0 AND line_kind = 'product' AND item_code IS NOT NULL AND doc_date BETWEEN :start AND :end
    AND (supplier_code = CAST(:supplier AS TEXT) OR lower(supplier_name) LIKE '%' || lower(trim(:supplier)) || '%')),
lastc AS (SELECT item_code, unit_cost_net, ROW_NUMBER() OVER (PARTITION BY item_code ORDER BY doc_date DESC) AS rn FROM l WHERE qty > 0),
sold AS (SELECT item_code, -SUM(qty) AS qty_sold FROM stock_movements
         WHERE movement_kind IN ('sale','sale_return') AND doc_date BETWEEN :start AND :end AND item_code IN (SELECT item_code FROM l) GROUP BY item_code)
SELECT MAX(l.supplier_name) AS supplier_name, l.item_code, MAX(l.description) AS description, MAX(l.group_name) AS group_name,
       SUM(l.qty) AS qty_bought, ROUND(SUM(l.net),2) AS spend, ROUND(SUM(l.net)/NULLIF(SUM(l.qty),0),2) AS avg_cost,
       ROUND(MAX(lc.unit_cost_net),2) AS last_cost, MAX(l.doc_date) AS last_bought, sold.qty_sold, si.qty_on_hand
FROM l
LEFT JOIN lastc lc ON lc.item_code = l.item_code AND lc.rn = 1
LEFT JOIN sold ON sold.item_code = l.item_code
LEFT JOIN stock_items si ON si.item_code = l.item_code
GROUP BY l.item_code
ORDER BY SUM(l.net) DESC
LIMIT :limit
