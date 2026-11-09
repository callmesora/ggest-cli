-- name: finance_profit_and_loss_by_year
-- description: Indicative management P&L per year (from 2021, when overheads start being recorded): net sales and estimated gross margin (sales_facts) minus operating overheads net of VAT (Cab_DirCC_Cre: staff, rents, other running costs) = indicative operating result (before depreciation, interest and income tax). Investments (vehicles, furniture, solar panels), loan instalments and taxes are shown separately and NOT deducted. cutoff_mmdd limits each year to 01-01..cutoff for like-for-like.
-- params: start_year=2021, end_year=2026, cutoff_mmdd=12-31
WITH s AS (SELECT year, SUM(net) AS sales, SUM(margin) AS margin FROM sales_facts
           WHERE substr(doc_date,6,5) <= :cutoff_mmdd GROUP BY year),
e AS (
  SELECT CAST(substr(d.data_doc,1,4) AS INTEGER) AS year, d.entidade_codigo AS code,
         lower(trim(d.entidade_descricao)) AS name, lower(COALESCE(d.descritivo,'')) AS txt,
         CASE WHEN d.Codigo = 'NCOC' THEN -1 ELSE 1 END * (CAST(d.total_documento AS REAL) - CAST(d.Total_iva AS REAL)) AS net
  FROM Cab_DirCC_Cre d
  WHERE d.Codigo IN ('FTOC','FROC','NCOC') AND d.estado_doc <> '1' AND d.data_doc <> ''
    AND substr(d.data_doc,5,4) <= replace(:cutoff_mmdd,'-','')),
c AS (
  SELECT year, net,
    CASE WHEN code IN ('43','1') OR name LIKE '%penhora%' THEN 'staff'
         WHEN code IN ('139','191') OR txt LIKE 'renda%' THEN 'rent'
         WHEN code IN ('190','377','276') OR (code = '137' AND (txt LIKE '%painei%' OR txt LIKE '%fotovolt%' OR txt LIKE '%bateria%')) THEN 'investment'
         WHEN code = '380' OR (code = '15' AND txt LIKE '%empr%stimo%') THEN 'loans'
         WHEN code = '38' THEN 'taxes'
         ELSE 'other_opex' END AS kind
  FROM e),
o AS (SELECT year, SUM(CASE WHEN kind='staff' THEN net ELSE 0 END) AS staff, SUM(CASE WHEN kind='rent' THEN net ELSE 0 END) AS rent,
             SUM(CASE WHEN kind='other_opex' THEN net ELSE 0 END) AS other_opex, SUM(CASE WHEN kind='investment' THEN net ELSE 0 END) AS investment,
             SUM(CASE WHEN kind='loans' THEN net ELSE 0 END) AS loans, SUM(CASE WHEN kind='taxes' THEN net ELSE 0 END) AS taxes
      FROM c GROUP BY year)
SELECT s.year, ROUND(s.sales,0) AS net_sales, ROUND(s.margin,0) AS gross_margin, ROUND(100.0*s.margin/s.sales,1) AS gross_margin_pct,
       ROUND(o.staff,0) AS staff_costs, ROUND(o.rent,0) AS rents, ROUND(o.other_opex,0) AS other_overheads,
       ROUND(o.staff + o.rent + o.other_opex,0) AS total_overheads,
       ROUND(s.margin - (o.staff + o.rent + o.other_opex),0) AS operating_result_indicative,
       ROUND(100.0*(s.margin - (o.staff + o.rent + o.other_opex))/s.sales,1) AS operating_margin_pct,
       ROUND(o.investment,0) AS investments_not_deducted, ROUND(o.loans,0) AS loan_instalments_not_deducted,
       ROUND(o.taxes,0) AS taxes_paid_not_deducted
FROM s JOIN o ON o.year = s.year
WHERE s.year BETWEEN :start_year AND :end_year ORDER BY s.year
