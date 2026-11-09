-- name: sales_discounts_by_year
-- description: Explicit discounts per year from the sales document totals (cab_vendas total_descontos_lin = line discounts, total_descontos_cab = header/global discount; credit notes negative; cancelled and internal documents excluded): documents with a discount, discount amounts, net sales and discount as % of (net + discount). Shows how much is given away through gGest's discount fields; price cuts typed directly into the unit price are not counted here (see sales_discounted_lines).
-- params: start_year=2017, end_year=this_year
WITH d AS (
  SELECT CAST(substr(v.data_doc,1,4) AS INTEGER) AS year, dt.sign,
         CAST(v.total_documento AS REAL) - CAST(v.Total_iva AS REAL) AS net,
         CAST(v.total_descontos_lin AS REAL) AS dl, CAST(v.total_descontos_cab AS REAL) AS dc
  FROM cab_vendas v JOIN doc_types dt ON dt.doc_type = v.Codigo
  WHERE dt.module = 'VND' AND dt.doc_class IN ('invoice','credit_note') AND dt.is_internal = 0 AND v.serie NOT LIKE 'VIA%'
    AND v.estado_doc <> '1' AND v.data_doc <> '' AND CAST(substr(v.data_doc,1,4) AS INTEGER) BETWEEN :start_year AND :end_year)
SELECT year, COUNT(*) AS documents, SUM(dl + dc > 0) AS docs_with_discount,
       ROUND(SUM(sign * dl), 2) AS line_discounts, ROUND(SUM(sign * dc), 2) AS header_discounts,
       ROUND(SUM(sign * net), 2) AS net_sales,
       ROUND(100.0 * SUM(sign * (dl + dc)) / NULLIF(SUM(sign * net) + SUM(sign * (dl + dc)), 0), 2) AS discount_pct
FROM d GROUP BY year ORDER BY year
LIMIT 100
