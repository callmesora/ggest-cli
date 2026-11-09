-- name: stock_reconciliation_check
-- description: Data-quality check of the stock quantity: for each item, opening balance of the current year (gGest year-closing _FE01) + this year's movements (stock_movements) should equal the stock on the item card (Artigos.stock_real). Returns ONLY the items that do not reconcile, plus a first summary row (item_code = '*TOTAL*': items checked, items matching). Normally > 99.5% match; differences come from movements recorded outside the standard documents or manual card edits.
-- params: limit=50
WITH yr AS (SELECT MAX(CAST(ano AS INTEGER)) AS y FROM Lin_Stocks WHERE Codigo = '_FE01'),
op AS (SELECT item_code, SUM(qty) AS q FROM stock_year_end WHERE year = (SELECT y - 1 FROM yr) GROUP BY item_code),
mv AS (SELECT item_code, SUM(qty) AS q FROM stock_movements WHERE year = (SELECT y FROM yr) GROUP BY item_code),
k AS (SELECT item_code FROM op UNION SELECT item_code FROM mv UNION SELECT item_code FROM stock_items WHERE qty_on_hand <> 0),
r AS (
  SELECT k.item_code, COALESCE(st.description, '(not in catalogue)') AS description, COALESCE(op.q,0) AS opening_qty, COALESCE(mv.q,0) AS movements_qty,
         COALESCE(op.q,0) + COALESCE(mv.q,0) AS expected_qty, COALESCE(st.qty_on_hand, 0) AS stock_on_card
  FROM k LEFT JOIN op ON op.item_code = k.item_code LEFT JOIN mv ON mv.item_code = k.item_code LEFT JOIN stock_items st ON st.item_code = k.item_code)
SELECT '*TOTAL*' AS item_code, 'items checked / matching' AS description, COUNT(*) AS opening_qty,
       SUM(ABS(expected_qty - stock_on_card) < 0.001) AS movements_qty, NULL AS expected_qty, NULL AS stock_on_card, NULL AS difference
FROM r
UNION ALL
SELECT * FROM (
  SELECT item_code, description, opening_qty, movements_qty, expected_qty, stock_on_card, stock_on_card - expected_qty AS difference
  FROM r WHERE ABS(expected_qty - stock_on_card) >= 0.001 ORDER BY ABS(stock_on_card - expected_qty) DESC LIMIT :limit)
