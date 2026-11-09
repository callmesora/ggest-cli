-- name: sales_chip7_vs_shop_by_year
-- description: Chip7 franchise sales (invoice series CHIP*) vs the rest of the shop, per year: net sales, gross margin, margin %, documents
-- params: start_year=2022, end_year=2026
SELECT year,
       ROUND(SUM(CASE WHEN doc_id LIKE '% CHIP%' THEN net END), 2) AS chip7_net,
       ROUND(SUM(CASE WHEN doc_id LIKE '% CHIP%' THEN margin END), 2) AS chip7_margin,
       ROUND(100.0 * SUM(CASE WHEN doc_id LIKE '% CHIP%' THEN margin END) / NULLIF(SUM(CASE WHEN doc_id LIKE '% CHIP%' THEN net END), 0), 1) AS chip7_margin_pct,
       COUNT(DISTINCT CASE WHEN doc_id LIKE '% CHIP%' THEN doc_id END) AS chip7_documents,
       ROUND(SUM(CASE WHEN doc_id NOT LIKE '% CHIP%' THEN net END), 2) AS shop_net,
       ROUND(100.0 * SUM(CASE WHEN doc_id NOT LIKE '% CHIP%' THEN margin END) / NULLIF(SUM(CASE WHEN doc_id NOT LIKE '% CHIP%' THEN net END), 0), 1) AS shop_margin_pct,
       ROUND(100.0 * SUM(CASE WHEN doc_id LIKE '% CHIP%' THEN net END) / SUM(net), 1) AS chip7_share_pct
FROM sales_facts
WHERE year BETWEEN :start_year AND :end_year
GROUP BY year ORDER BY year
