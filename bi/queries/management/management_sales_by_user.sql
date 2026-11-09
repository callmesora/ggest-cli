-- name: management_sales_by_user
-- description: Sales documents, net sales, average ticket and cancellation rate per gGest user (who issued the document), per year
-- params: start_year=2022, end_year=this_year
SELECT d.year, COALESCE(u.descricao, 'user ' || d.created_by_user) AS user_name,
       SUM(d.is_cancelled = 0) AS documents,
       ROUND(SUM(CASE WHEN d.is_cancelled = 0 THEN d.net END), 0) AS net_sales,
       ROUND(SUM(CASE WHEN d.is_cancelled = 0 THEN d.net END) / NULLIF(SUM(d.is_cancelled = 0), 0), 0) AS avg_ticket,
       ROUND(100.0 * SUM(d.is_cancelled) / COUNT(*), 1) AS cancelled_pct
FROM sales_docs d LEFT JOIN utilizadores u ON u.Codigo = d.created_by_user
WHERE d.is_internal = 0 AND d.year BETWEEN :start_year AND :end_year
GROUP BY 1, 2 ORDER BY 1, 4 DESC
