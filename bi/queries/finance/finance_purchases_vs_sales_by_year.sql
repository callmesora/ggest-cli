-- name: finance_purchases_vs_sales_by_year
-- description: Purchases (supplier invoices net of VAT, credit notes negative, read from raw cab_compras so intra-EU FTINC invoices count POSITIVE) vs net sales, product COGS and estimated margin from sales_facts, per year. implied_margin_pct = (sales - purchases) / sales is a cash cross-check of the sales_facts margin; purchases_minus_cogs > 0 means stock was built up. cutoff_mmdd limits every year to 01-01..cutoff for like-for-like comparisons (e.g. 11-07).
-- params: start_year=2017, end_year=2026, cutoff_mmdd=12-31
WITH p AS (
  SELECT CAST(substr(data_doc,1,4) AS INTEGER) AS year,
         SUM(CASE WHEN Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END
             * (CAST(total_documento AS REAL) - CAST(Total_iva AS REAL))) AS purchases_net,
         COUNT(*) AS purchase_docs
  FROM cab_compras
  WHERE estado_doc <> '1' AND data_doc <> '' AND substr(data_doc,5,4) <= replace(:cutoff_mmdd,'-','')
  GROUP BY 1),
s AS (
  SELECT year, SUM(net) AS sales_net, SUM(CASE WHEN line_kind = 'product' THEN net END) AS product_sales_net,
         SUM(cost) AS cogs, SUM(margin) AS margin
  FROM sales_facts WHERE substr(doc_date,6,5) <= :cutoff_mmdd GROUP BY year)
SELECT s.year, ROUND(s.sales_net,0) AS sales_net, ROUND(s.product_sales_net,0) AS product_sales_net,
       ROUND(p.purchases_net,0) AS purchases_net, ROUND(s.cogs,0) AS cogs_sales_facts,
       ROUND(100.0 * s.margin / s.sales_net,1) AS margin_pct_sales_facts,
       ROUND(100.0 * (s.sales_net - p.purchases_net) / s.sales_net,1) AS implied_margin_pct_purchases,
       ROUND(100.0 * p.purchases_net / s.sales_net,1) AS purchases_pct_of_sales,
       ROUND(p.purchases_net - s.cogs,0) AS purchases_minus_cogs, p.purchase_docs
FROM s LEFT JOIN p ON p.year = s.year
WHERE s.year BETWEEN :start_year AND :end_year
ORDER BY s.year
