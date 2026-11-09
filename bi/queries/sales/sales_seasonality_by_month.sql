-- name: sales_seasonality_by_month
-- description: Seasonality: average / min / max net sales, margin %, invoices and share of the year per calendar month across complete years (default 2017 to last year).
-- params: start_year=2017, end_year=last_year
WITH m AS (SELECT year, CAST(substr(month, 6, 2) AS INTEGER) AS month_no, SUM(net) AS net, SUM(margin) AS margin,
                  COUNT(DISTINCT CASE WHEN doc_class = 'invoice' THEN doc_id END) AS invoices
           FROM sales_facts WHERE year BETWEEN :start_year AND :end_year GROUP BY year, month_no)
SELECT month_no, COUNT(*) AS years, ROUND(AVG(net), 2) AS avg_net_sales, ROUND(MIN(net), 2) AS min_net_sales,
       ROUND(MAX(net), 2) AS max_net_sales, ROUND(100.0 * SUM(margin) / SUM(net), 1) AS margin_pct,
       ROUND(AVG(invoices), 1) AS avg_invoices,
       ROUND(100.0 * SUM(net) / (SELECT SUM(net) FROM m), 1) AS share_of_year_pct
FROM m GROUP BY month_no ORDER BY month_no
