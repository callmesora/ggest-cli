-- name: stock_movements_by_year
-- description: Where stock goes: units and value at cost of every kind of stock movement per year (purchases, purchase returns, sales, sale returns, PC assembly in/out, miscellaneous adjustments in/out, write-offs, internal use, warranty/workshop use, loans, sponsorship). Exits are negative. Highlights stock leaving without a sale (adjustment_out = gGest "Saídas diversas", write_off = "abate"). Columns: year, movement_kind, documents, lines, units, value_at_cost.
-- params: from_year=years_ago_3
SELECT year, movement_kind, COUNT(DISTINCT doc_id) AS documents, COUNT(*) AS lines,
       ROUND(SUM(qty),0) AS units, ROUND(SUM(value_at_cost),0) AS value_at_cost
FROM stock_movements
WHERE year >= CAST(:from_year AS INTEGER)
GROUP BY year, movement_kind
ORDER BY year, CASE WHEN SUM(qty) >= 0 THEN 0 ELSE 1 END, ABS(SUM(value_at_cost)) DESC
