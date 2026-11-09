-- name: sales_low_margin_items
-- description: Products sold with low or negative gross margin in a period (margin % <= max_margin_pct and sales >= min_net), with cost sources so data errors (unit mismatch, wrong fallback cost) can be told apart from real under-pricing. total_items / total_gross_margin cover ALL matching items, not only the rows shown.
-- params: start=last_year_start, end=today, max_margin_pct=10, min_net=300, limit=50
SELECT f.item_code, COALESCE(MAX(i.description), MAX(f.item_description)) AS description, MAX(f.group_name) AS group_name,
       MAX(f.family_name) AS family_name, MAX(f.brand_name) AS brand_name,
       ROUND(SUM(f.qty), 2) AS qty, ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.cost), 2) AS cost,
       ROUND(SUM(f.margin), 2) AS gross_margin, ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       GROUP_CONCAT(DISTINCT f.cost_source) AS cost_sources, COUNT(DISTINCT f.doc_id) AS documents,
       COUNT(*) OVER () AS total_items, ROUND(SUM(SUM(f.margin)) OVER (), 2) AS total_gross_margin
FROM sales_facts f LEFT JOIN items i ON i.item_code = f.item_code
WHERE f.doc_date BETWEEN :start AND :end AND f.line_kind = 'product' AND upper(f.item_code) <> 'ZZ'
GROUP BY f.item_code
HAVING SUM(f.net) >= :min_net AND 100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0) <= :max_margin_pct
ORDER BY gross_margin ASC LIMIT :limit
