-- name: stock_value_by_year
-- description: Year-end stock value at cost per year (gGest year-closing balances, same totals as the AT inventory communication) plus the current stock as the last row, with cost of goods sold (sales_facts cost of product lines), net purchases (purchase_docs), stock turnover (COGS / average of opening and closing stock) and days of stock (365 / turnover). Columns: year, items_in_stock, units, stock_value, cogs, purchases_net, turnover, days_of_stock. The current-year row uses today's stock and year-to-date COGS (partial year: turnover not annualised). `from_year` empty = all years (from 2017).
-- params: from_year=
WITH ye AS (
  SELECT year, COUNT(*) AS items, SUM(qty) AS units, SUM(stock_value) AS stock_value FROM stock_year_end GROUP BY year
  UNION ALL
  SELECT CAST(strftime('%Y', (SELECT MAX(doc_date) FROM sales_facts)) AS INTEGER), COUNT(*), SUM(qty_on_hand), SUM(stock_value)
  FROM stock_items WHERE kind = 'product' AND qty_on_hand > 0),
cogs AS (SELECT year, SUM(cost) AS cogs FROM sales_facts WHERE line_kind = 'product' GROUP BY year),
pur AS (SELECT year, SUM(net) AS purchases_net FROM purchase_docs WHERE is_cancelled = 0 GROUP BY year)
SELECT ye.year, ye.items AS items_in_stock, ROUND(ye.units,0) AS units, ROUND(ye.stock_value,0) AS stock_value,
       ROUND(cogs.cogs,0) AS cogs, ROUND(pur.purchases_net,0) AS purchases_net,
       ROUND(cogs.cogs / ((COALESCE(prev.stock_value, ye.stock_value) + ye.stock_value) / 2.0), 1) AS turnover,
       ROUND(365.0 / (cogs.cogs / ((COALESCE(prev.stock_value, ye.stock_value) + ye.stock_value) / 2.0)), 0) AS days_of_stock
FROM ye
LEFT JOIN ye prev ON prev.year = ye.year - 1
LEFT JOIN cogs ON cogs.year = ye.year
LEFT JOIN pur ON pur.year = ye.year
WHERE (:from_year = '' OR ye.year >= CAST(:from_year AS INTEGER))
ORDER BY ye.year
