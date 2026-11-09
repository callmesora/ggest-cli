-- name: finance_top_suppliers
-- description: Supplier ranking by net purchases in a period (raw cab_compras, VAT excluded, credit notes negative, FTINC positive) with share, cumulative share (concentration), documents, first/last purchase and country. Note 2017 includes a one-off opening-stock transfer (VFT RV17/12017, ~49k EUR).
-- params: start=2017-01-01, end=today, limit=25
WITH p AS (
  SELECT c.entidade_codigo AS supplier_code,
         CASE WHEN c.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END
           * (CAST(c.total_documento AS REAL) - CAST(c.Total_iva AS REAL)) AS net,
         date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS doc_date,
         c.Codigo AS doc_type, lower(trim(c.entidade_pais)) AS country
  FROM cab_compras c WHERE c.estado_doc <> '1' AND c.data_doc <> ''),
f AS (SELECT * FROM p WHERE doc_date BETWEEN :start AND :end),
g AS (SELECT supplier_code, SUM(net) AS net, COUNT(*) AS docs, MIN(doc_date) AS first_purchase, MAX(doc_date) AS last_purchase,
             MAX(NULLIF(country,'')) AS country
      FROM f GROUP BY supplier_code)
SELECT g.supplier_code, COALESCE(s.name, '?') AS supplier, ROUND(g.net,0) AS net_purchases, g.docs,
       ROUND(100.0 * g.net / (SELECT SUM(net) FROM g),1) AS share_pct,
       ROUND(100.0 * SUM(g.net) OVER (ORDER BY g.net DESC ROWS UNBOUNDED PRECEDING) / (SELECT SUM(net) FROM g),1) AS cumulative_pct,
       g.first_purchase, g.last_purchase, g.country
FROM g LEFT JOIN suppliers s ON s.supplier_code = g.supplier_code
ORDER BY g.net DESC LIMIT :limit
