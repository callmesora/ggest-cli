-- name: finance_purchases_by_origin
-- description: Net purchases per year by supplier origin: mainland/Portuguese suppliers (VFT with country Portugal or blank), foreign suppliers invoiced on a normal VFT, intra-EU (FTINC, VAT reverse-charged) and extra-EU (FTEXC). Credit notes negative; FADIA/NCADI advance invoices net to ~0.
-- params: start_year=2017, end_year=this_year
WITH p AS (
  SELECT CAST(substr(data_doc,1,4) AS INTEGER) AS year,
         CASE WHEN Codigo = 'FTINC' THEN '2 UE intracomunitaria (FTINC)'
              WHEN Codigo = 'FTEXC' THEN '3 Extra-UE (FTEXC)'
              WHEN lower(trim(entidade_pais)) IN ('', 'portugal') THEN '1 Portugal'
              ELSE '4 Estrangeiro em fatura normal' END AS origin,
         CASE WHEN Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END
           * (CAST(total_documento AS REAL) - CAST(Total_iva AS REAL)) AS net,
         CASE WHEN Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * CAST(Total_iva AS REAL) AS vat
  FROM cab_compras WHERE estado_doc <> '1' AND data_doc <> '')
SELECT year, origin, COUNT(*) AS docs, ROUND(SUM(net),0) AS net_purchases, ROUND(SUM(vat),0) AS vat_paid,
       ROUND(100.0 * SUM(net) / SUM(SUM(net)) OVER (PARTITION BY year),2) AS share_of_year_pct
FROM p WHERE year BETWEEN :start_year AND :end_year
GROUP BY year, origin ORDER BY year, origin
