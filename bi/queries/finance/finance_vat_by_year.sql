-- name: finance_vat_by_year
-- description: Indicative VAT position per year: VAT charged on sales documents (sales_docs, not cancelled, incl. internal docs; credit notes negative) minus VAT on supplier invoices (cab_compras) and on overhead invoices (Cab_DirCC_Cre, from 2021). Positive = VAT to pay to the State. Sales are taxed at the Azores rate (18% -> 16% from mid-2021) while most purchases come from the mainland at 23%, so the net is small. Not a tax return: excludes reverse-charge self-assessment and adjustments.
-- params: start_year=2017, end_year=2026
WITH s AS (SELECT year, SUM(vat) AS vat_sales, SUM(net) AS net_sales FROM sales_docs
           WHERE is_cancelled = 0 AND doc_class IN ('invoice','credit_note') GROUP BY year),
p AS (SELECT CAST(substr(data_doc,1,4) AS INTEGER) AS year,
             SUM(CASE WHEN Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * CAST(Total_iva AS REAL)) AS vat_purchases,
             SUM(CASE WHEN Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * (CAST(total_documento AS REAL) - CAST(Total_iva AS REAL))) AS net_purchases
      FROM cab_compras WHERE estado_doc <> '1' AND data_doc <> '' GROUP BY 1),
o AS (SELECT CAST(substr(data_doc,1,4) AS INTEGER) AS year,
             SUM(CASE WHEN Codigo = 'NCOC' THEN -1 ELSE 1 END * CAST(Total_iva AS REAL)) AS vat_overheads
      FROM Cab_DirCC_Cre WHERE Codigo IN ('FTOC','FROC','NCOC') AND estado_doc <> '1' AND data_doc <> '' GROUP BY 1)
SELECT s.year, ROUND(s.vat_sales,0) AS vat_collected, ROUND(100.0 * s.vat_sales / s.net_sales,2) AS avg_sales_rate_pct,
       ROUND(p.vat_purchases,0) AS vat_on_purchases, ROUND(100.0 * p.vat_purchases / p.net_purchases,2) AS avg_purchase_rate_pct,
       ROUND(o.vat_overheads,0) AS vat_on_overheads,
       ROUND(s.vat_sales - COALESCE(p.vat_purchases,0) - COALESCE(o.vat_overheads,0),0) AS net_vat_position
FROM s LEFT JOIN p ON p.year = s.year LEFT JOIN o ON o.year = s.year
WHERE s.year BETWEEN :start_year AND :end_year ORDER BY s.year
