-- name: stock_assembly_by_year
-- description: PC/solution assembly activity per year (gGest "Produção (composição)": components leave stock, the built item enters): assembly orders, units built, total cost of components, average cost per unit, component lines used, and how the built items sold (units sold, net sales and gross margin from sales_facts for the assembled item codes, any year; generic codes reused for many PCs — e.g. one generic "computer" code in 2020 — inflate these sales). Columns: year, assemblies, units_built, components_cost, avg_unit_cost, component_lines, units_sold, sales_net, margin, margin_pct.
-- params: from_year=
WITH a AS (
  SELECT year, COUNT(*) AS assemblies, SUM(qty) AS units_built, SUM(total_cost) AS components_cost, SUM(component_lines) AS component_lines
  FROM assembly_orders GROUP BY year),
s AS (
  SELECT o.year, SUM(f.qty) AS units_sold, SUM(f.net) AS sales_net, SUM(f.margin) AS margin
  FROM (SELECT item_code, MIN(year) AS year FROM assembly_orders GROUP BY item_code) o
  JOIN sales_facts f ON f.item_code = o.item_code
  GROUP BY o.year)
SELECT a.year, a.assemblies, a.units_built, ROUND(a.components_cost,0) AS components_cost,
       ROUND(a.components_cost / NULLIF(a.units_built,0),0) AS avg_unit_cost, a.component_lines,
       s.units_sold, ROUND(s.sales_net,0) AS sales_net, ROUND(s.margin,0) AS margin,
       ROUND(100.0 * s.margin / NULLIF(s.sales_net,0),1) AS margin_pct
FROM a LEFT JOIN s ON s.year = a.year
WHERE (:from_year = '' OR a.year >= CAST(:from_year AS INTEGER))
ORDER BY a.year
