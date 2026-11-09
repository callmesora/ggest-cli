-- name: sales_item_search_by_year
-- description: Sales per year of every line whose item description, item code, family or brand matches a text pattern (SQL LIKE, case-insensitive; e.g. pattern=%recondicionad% or %reacondicionad%, %mini pc%, %apple%, %remot%), to size a product family that the catalogue groups don't isolate (refurbished PCs, remote support, a model range). Columns: year, lines, documents, customers, qty, net sales, gross margin, margin %, share of the year's total sales. Matching is on the text printed on the invoice line, so it also catches the generic ZZ item. Use pattern2 for an OR alternative ('' = none).
-- params: pattern=%recondicionad%, pattern2=%reacondicionad%, start_year=2017, end_year=this_year
WITH t AS (SELECT year, SUM(net) AS total FROM sales_facts WHERE year BETWEEN :start_year AND :end_year GROUP BY year)
SELECT f.year, COUNT(*) AS lines, COUNT(DISTINCT f.doc_id) AS documents, COUNT(DISTINCT f.customer_code) AS customers,
       ROUND(SUM(f.qty), 1) AS qty, ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       ROUND(100.0 * SUM(f.net) / MAX(t.total), 2) AS share_of_sales_pct
FROM sales_facts f JOIN t ON t.year = f.year
WHERE f.year BETWEEN :start_year AND :end_year
  AND (lower(f.item_description) LIKE lower(:pattern) OR lower(f.item_code) LIKE lower(:pattern)
       OR lower(COALESCE(f.family_name, '')) LIKE lower(:pattern) OR lower(COALESCE(f.brand_name, '')) LIKE lower(:pattern)
       OR (:pattern2 <> '' AND (lower(f.item_description) LIKE lower(:pattern2) OR lower(COALESCE(f.family_name, '')) LIKE lower(:pattern2))))
GROUP BY f.year ORDER BY f.year
LIMIT 100
